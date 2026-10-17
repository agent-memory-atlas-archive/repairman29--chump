//! RESILIENT-1615: two-scope node enumeration.
//!
//! A converged node must have exactly ONE chump install in ONE supervisor
//! scope. cuphead ran a SECOND, root/system-scope install (out of
//! `/root/.chumpnode/repo`, 60+ enabled `chump-*` units under
//! `/etc/systemd/system`) alongside the ubuntu user-scope install for 24 days.
//! The user-scope `chump node pause` never touched the system-scope organs, so
//! cut PRs were reopened four times and converge re-enabled timers.
//!
//! This module owns the INVARIANT (Rust owns invariants, shell owns glue):
//!   * classify a `chump-*` unit as a WORK organ (installs/enables/restarts) vs
//!     a read-only SUBSTRATE organ that is fine to leave running when paused;
//!   * parse `systemctl list-units` / `list-unit-files` and `launchctl list`
//!     output (pure, so the CI fixture can stub both scopes);
//!   * aggregate per-scope [`ScopeScan`]s into the two cross-scope predicates
//!     the verbs enforce: "any work organ active?" ([`any_work_active`]) and
//!     "installed in more than one scope?" ([`two_scope_installed`]).
//!
//! The live `systemctl`/`launchctl` runner and the CLI live in `src/` (glue);
//! everything here is pure and unit-tested.

use crate::RunScope;

/// Substrate / read-only organs kept running on purpose even on a paused node
/// (they neither install, enable, nor restart work units). A unit whose
/// basename contains one of these markers is NOT a work organ, so its being
/// active does not block a PAUSED report. Everything else named `chump-*`
/// (or `com.chump.*` / `dev.chump.*`) is treated as a work organ —
/// fail-TOWARD-refusing-PAUSED when a unit is unknown.
///
/// Sourced from the 2026-10-17 cuphead triage (gap RESILIENT-1615 notes): the
/// "kept on purpose (read-only or substrate)" list the session classifier
/// refused to disable.
pub const SUBSTRATE_MARKERS: &[&str] = &[
    "almanac-liveness",
    "digest",
    "gap-closure-reconcile",
    "gap-store-single-source-check",
    "fleet-health-sentinel",
    "disk", // chump-disk-health-monitor, disk-pressure, any disk monitor
    "node-heartbeat",
    "fleet-server",
    "discord-gateway",
    "cargo", // chump-cargo-sweep-gc, cargo-target-reaper — housekeeping
    "worktree-reaper",
    "jeff-bus-ingest",
    "holler-drain",
    "sla-scorecard",
    "security-audit",
    "faculty-collector",
    "state-audit",
    "queue-health-monitor",
    "trunk-sentinel",
];

/// The last path component of a unit name or launchd label, with a trailing
/// supervisor suffix (`.service` / `.timer` / `.plist`) stripped so a path like
/// `/etc/systemd/system/chump-foo.service` and a bare `chump-foo.timer` and a
/// label `com.chump.foo` all compare on the same stem.
pub fn unit_basename(name: &str) -> &str {
    let b = name.rsplit(['/', '\\']).next().unwrap_or(name);
    for suf in [
        ".service", ".timer", ".socket", ".path", ".target", ".plist",
    ] {
        if let Some(stem) = b.strip_suffix(suf) {
            return stem;
        }
    }
    b
}

/// Is this a chump supervisor unit at all? Matches the `chump-*` systemd
/// convention and the `com.chump.*` / `dev.chump.*` launchd label convention.
pub fn is_chump_unit(name: &str) -> bool {
    let b = unit_basename(name);
    b.starts_with("chump-")
        || b.starts_with("chump.")
        || b.starts_with("com.chump.")
        || b.starts_with("dev.chump.")
}

/// Is this a chump WORK organ (one that installs / enables / restarts / mutates
/// fleet state)? Only [`is_chump_unit`] names qualify; a [`SUBSTRATE_MARKERS`]
/// match demotes it to a non-work, keep-running organ.
pub fn is_work_organ(name: &str) -> bool {
    if !is_chump_unit(name) {
        return false;
    }
    let b = unit_basename(name);
    !SUBSTRATE_MARKERS.iter().any(|m| b.contains(m))
}

/// One supervisor unit observed in a scope.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Unit {
    pub name: String,
    /// `active`/`activating` (systemd) or a live PID (launchd).
    pub active: bool,
    /// an `enabled` unit-file (systemd) or simply loaded (launchd).
    pub enabled: bool,
}

/// Everything found in one supervisor scope (`systemctl --user`, `systemctl`
/// system, or `launchctl` on mac).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScopeScan {
    pub scope: RunScope,
    /// install root for this scope if it exists on disk (e.g. `/root/.chumpnode`
    /// or `~/.chumpnode`); `None` when absent.
    pub root: Option<String>,
    pub units: Vec<Unit>,
}

impl ScopeScan {
    /// Build a scan from the two systemd queries plus an on-disk root probe.
    /// `list_units` is `systemctl [--user] list-units --type=service,timer
    /// --all --no-legend 'chump-*'`; `list_unit_files` is the matching
    /// `list-unit-files`. Enabled state comes from the unit-files query, active
    /// state from the units query; the two are unioned by unit name.
    pub fn from_systemctl(
        scope: RunScope,
        list_units: &str,
        list_unit_files: &str,
        root: Option<String>,
    ) -> ScopeScan {
        let active = parse_list_units(list_units);
        let enabled = parse_list_unit_files(list_unit_files);
        let mut names: Vec<String> = Vec::new();
        for (n, _) in active.iter().chain(enabled.iter()) {
            if is_chump_unit(n) && !names.iter().any(|x| x == n) {
                names.push(n.clone());
            }
        }
        let units = names
            .into_iter()
            .map(|name| {
                let active = active.iter().any(|(n, a)| *a && n == &name);
                let enabled = enabled.iter().any(|(n, e)| *e && n == &name);
                Unit {
                    name,
                    active,
                    enabled,
                }
            })
            .collect();
        ScopeScan { scope, root, units }
    }

    /// Build a scan from `launchctl list` output (mac user domain). A row with a
    /// numeric PID is active; every listed chump label is treated as enabled.
    pub fn from_launchctl(
        scope: RunScope,
        launchctl_list: &str,
        root: Option<String>,
    ) -> ScopeScan {
        let units = parse_launchctl_list(launchctl_list)
            .into_iter()
            .filter(|(n, _)| is_chump_unit(n))
            .map(|(name, active)| Unit {
                name,
                active,
                enabled: true,
            })
            .collect();
        ScopeScan { scope, root, units }
    }

    /// Work organs currently active in this scope.
    pub fn active_work_organs(&self) -> Vec<&str> {
        self.units
            .iter()
            .filter(|u| u.active && is_work_organ(&u.name))
            .map(|u| u.name.as_str())
            .collect()
    }

    /// chump units with an enabled unit-file in this scope (work or substrate).
    pub fn enabled_units(&self) -> Vec<&str> {
        self.units
            .iter()
            .filter(|u| u.enabled)
            .map(|u| u.name.as_str())
            .collect()
    }

    /// Is a chump install present in this scope? True when its on-disk root
    /// exists OR any `chump-*` unit is enabled/active here. A node that merely
    /// *queried* a scope with nothing installed reads as not-installed.
    pub fn is_installed(&self) -> bool {
        self.root.is_some() || self.units.iter().any(|u| u.enabled || u.active)
    }
}

/// Parse `systemctl list-units --no-legend` rows into `(unit, active)`.
///
/// Row shape (a leading `●`/`*` failure bullet is optional):
///   `chump-foo.service  loaded active   running  Foo organ`
/// Columns after an optional bullet are UNIT LOAD ACTIVE SUB …; a unit counts
/// as active when its ACTIVE column is `active` or `activating`.
pub fn parse_list_units(stdout: &str) -> Vec<(String, bool)> {
    let mut out = Vec::new();
    for line in stdout.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let mut cols: Vec<&str> = line.split_whitespace().collect();
        if cols
            .first()
            .map(|c| *c == "●" || *c == "*")
            .unwrap_or(false)
        {
            cols.remove(0);
        }
        if cols.len() < 3 {
            continue;
        }
        let name = cols[0];
        let active_col = cols[2];
        let active = active_col == "active" || active_col == "activating";
        out.push((name.to_string(), active));
    }
    out
}

/// Parse `systemctl list-unit-files --no-legend` rows into `(unit, enabled)`.
///
/// Row shape: `chump-foo.service  enabled  enabled` — the STATE column is
/// column 2; a unit counts as enabled when STATE is `enabled` or
/// `enabled-runtime`.
pub fn parse_list_unit_files(stdout: &str) -> Vec<(String, bool)> {
    let mut out = Vec::new();
    for line in stdout.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let cols: Vec<&str> = line.split_whitespace().collect();
        if cols.len() < 2 {
            continue;
        }
        let name = cols[0];
        let state = cols[1];
        let enabled = state == "enabled" || state == "enabled-runtime";
        out.push((name.to_string(), enabled));
    }
    out
}

/// Parse `launchctl list` rows into `(label, active)`.
///
/// Row shape (tab- or space-separated): `PID  Status  Label`. A row whose PID
/// column is a number is active; `-` (no PID) is loaded-but-idle. The header
/// row (`PID\tStatus\tLabel`) is skipped.
pub fn parse_launchctl_list(stdout: &str) -> Vec<(String, bool)> {
    let mut out = Vec::new();
    for line in stdout.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with("PID") {
            continue;
        }
        let cols: Vec<&str> = line.split_whitespace().collect();
        if cols.len() < 3 {
            continue;
        }
        let pid = cols[0];
        let label = cols[cols.len() - 1];
        let active = pid.chars().all(|c| c.is_ascii_digit()) && !pid.is_empty();
        out.push((label.to_string(), active));
    }
    out
}

/// Escape a string for embedding in a JSON string literal (ambient events).
pub fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c => out.push(c),
        }
    }
    out
}

/// Total work organs active across every scanned scope.
pub fn any_work_active(scans: &[ScopeScan]) -> usize {
    scans.iter().map(|s| s.active_work_organs().len()).sum()
}

/// Work organs active in a scope OTHER than `current` — the organs a scope-local
/// `chump node pause` CANNOT reach. This is the number pause refuses to report
/// PAUSED over: a single-scope node's own organs drain on their next tick, but a
/// SECOND scope's organs (the cuphead root/system-scope install) never see the
/// user-scope sentinel and silently undo the pause.
pub fn work_active_in_other_scopes(scans: &[ScopeScan], current: RunScope) -> usize {
    scans
        .iter()
        .filter(|s| s.scope != current)
        .map(|s| s.active_work_organs().len())
        .sum()
}

/// Is a chump install present in more than one scope? The two-scope defect.
pub fn two_scope_installed(scans: &[ScopeScan]) -> bool {
    scans.iter().filter(|s| s.is_installed()).count() >= 2
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_work_vs_substrate() {
        assert!(is_work_organ("chump-node1-worker.service"));
        assert!(is_work_organ("chump-node-converge.timer"));
        assert!(is_work_organ(
            "/etc/systemd/system/chump-organ-deploy.service"
        ));
        assert!(is_work_organ("com.chump.reviver"));
        // substrate / read-only stay non-work
        assert!(!is_work_organ("chump-fleet-health-sentinel.service"));
        assert!(!is_work_organ("chump-node-heartbeat.timer"));
        assert!(!is_work_organ("chump-disk-monitor.service"));
        assert!(!is_work_organ("chump-trunk-sentinel.timer"));
        // non-chump units are never work organs
        assert!(!is_work_organ("ssh.service"));
        assert!(!is_work_organ("cron.timer"));
    }

    #[test]
    fn parses_list_units_with_and_without_bullet() {
        let out = "\
chump-worker.service        loaded active   running Worker
● chump-reviver.service     loaded failed   failed  Reviver
chump-converge.timer        loaded inactive dead    Converge
";
        let units = parse_list_units(out);
        assert_eq!(units.len(), 3);
        assert_eq!(units[0], ("chump-worker.service".to_string(), true));
        assert_eq!(units[1], ("chump-reviver.service".to_string(), false));
        assert_eq!(units[2], ("chump-converge.timer".to_string(), false));
    }

    #[test]
    fn parses_list_unit_files() {
        let out = "\
chump-worker.service   enabled         enabled
chump-converge.timer   disabled        disabled
chump-foo.service      enabled-runtime -
";
        let files = parse_list_unit_files(out);
        assert_eq!(files[0], ("chump-worker.service".to_string(), true));
        assert_eq!(files[1], ("chump-converge.timer".to_string(), false));
        assert_eq!(files[2], ("chump-foo.service".to_string(), true));
    }

    #[test]
    fn parses_launchctl_list() {
        let out = "\
PID\tStatus\tLabel
1234\t0\tcom.chump.worker
-\t0\tcom.chump.reviver
987\t0\tcom.apple.something
";
        let rows = parse_launchctl_list(out);
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0], ("com.chump.worker".to_string(), true));
        assert_eq!(rows[1], ("com.chump.reviver".to_string(), false));
        assert_eq!(rows[2], ("com.apple.something".to_string(), true));
    }

    #[test]
    fn scope_scan_counts_active_work_organs() {
        let units = "\
chump-worker.service              loaded active running W
chump-fleet-health-sentinel.service loaded active running S
chump-converge.timer              loaded inactive dead C
";
        let files = "\
chump-worker.service              enabled enabled
chump-fleet-health-sentinel.service enabled enabled
chump-converge.timer              enabled enabled
";
        let scan = ScopeScan::from_systemctl(RunScope::System, units, files, None);
        // worker is active+work; sentinel is active but substrate; converge is work but inactive
        assert_eq!(scan.active_work_organs(), vec!["chump-worker.service"]);
        assert_eq!(scan.enabled_units().len(), 3);
        assert!(scan.is_installed());
    }

    #[test]
    fn empty_scope_is_not_installed() {
        let scan = ScopeScan::from_systemctl(RunScope::User, "", "", None);
        assert!(!scan.is_installed());
        assert!(scan.active_work_organs().is_empty());
    }

    #[test]
    fn root_present_means_installed_even_with_no_units() {
        let scan = ScopeScan::from_systemctl(
            RunScope::System,
            "",
            "",
            Some("/root/.chumpnode".to_string()),
        );
        assert!(scan.is_installed());
    }

    #[test]
    fn two_scope_and_any_work_active_aggregate() {
        let user = ScopeScan::from_systemctl(
            RunScope::User,
            "chump-worker.service loaded active running W\n",
            "chump-worker.service enabled enabled\n",
            None,
        );
        let system = ScopeScan::from_systemctl(
            RunScope::System,
            "chump-reviver.service loaded active running R\n",
            "chump-reviver.service enabled enabled\n",
            Some("/root/.chumpnode".to_string()),
        );
        let scans = vec![user, system];
        assert!(two_scope_installed(&scans));
        assert_eq!(any_work_active(&scans), 2);

        // Only one scope installed -> not a two-scope node.
        let single = vec![ScopeScan::from_systemctl(
            RunScope::User,
            "chump-worker.service loaded active running W\n",
            "chump-worker.service enabled enabled\n",
            None,
        )];
        assert!(!two_scope_installed(&single));
        assert_eq!(any_work_active(&single), 1);
    }
}
