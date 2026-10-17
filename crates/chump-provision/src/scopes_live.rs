//! RESILIENT-1615: the live `systemctl`/`launchctl` runner and the
//! `chump node scopes` command — the glue that feeds the pure
//! [`crate::scopes`] invariant with real host state.
//!
//! `chump node scopes [--json]` enumerates chump units in BOTH the user
//! (`systemctl --user`) and system (`systemctl`) scopes — or the mac launchd
//! user domain — through the typed [`crate::Host`], prints the per-scope work
//! organ / enabled counts and install roots, and exits 3 when more than one
//! scope carries an install (the two-scope defect).
//!
//! `chump node scopes --install-guard` is the installer/converge pre-flight:
//! it refuses (exit 3, `kind=node_second_scope_refused`) when the OTHER scope
//! relative to this process already has a chump install, so a second scope is
//! never stacked onto a node that already has one.

use crate::scopes::{any_work_active, two_scope_installed, work_active_in_other_scopes, ScopeScan};
use crate::{Probe, RunScope};
use std::path::Path;
use std::process::Command;

/// Run a command, returning trimmed stdout on success and an empty string on
/// any failure (missing binary, no user bus, non-zero exit). The scan degrades
/// to "nothing found" rather than erroring — a query failure must never make
/// `chump node pause` claim fewer organs than exist, nor crash a converge tick.
fn cmd_stdout(prog: &str, args: &[&str]) -> String {
    match Command::new(prog).args(args).output() {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => String::new(),
    }
}

/// The on-disk install root for a scope, if it exists.
///   * system  -> `/root/.chumpnode`
///   * user    -> `$CHUMP_NODE_DIR` or `$HOME/.chumpnode`
fn root_for(scope: RunScope, probe: &Probe) -> Option<String> {
    let candidate = match scope {
        RunScope::System => "/root/.chumpnode".to_string(),
        RunScope::User => std::env::var("CHUMP_NODE_DIR").unwrap_or_else(|_| {
            let home = probe.home.clone().unwrap_or_default();
            format!("{home}/.chumpnode")
        }),
    };
    if !candidate.is_empty() && Path::new(&candidate).exists() {
        Some(candidate)
    } else {
        None
    }
}

/// Scan one systemd scope (`--user` when `user_flag` is set, else system).
fn scan_systemd(scope: RunScope, user_flag: bool, probe: &Probe) -> ScopeScan {
    let scope_args: &[&str] = if user_flag { &["--user"] } else { &[] };
    let mut units_args: Vec<&str> = scope_args.to_vec();
    units_args.extend_from_slice(&[
        "list-units",
        "--type=service,timer",
        "--all",
        "--no-legend",
        "chump-*",
    ]);
    let mut files_args: Vec<&str> = scope_args.to_vec();
    files_args.extend_from_slice(&["list-unit-files", "--no-legend", "chump-*"]);

    let list_units = cmd_stdout("systemctl", &units_args);
    let list_unit_files = cmd_stdout("systemctl", &files_args);
    ScopeScan::from_systemctl(scope, &list_units, &list_unit_files, root_for(scope, probe))
}

/// Scan the mac launchd user domain.
fn scan_launchd(probe: &Probe) -> ScopeScan {
    let out = cmd_stdout("launchctl", &["list"]);
    ScopeScan::from_launchctl(RunScope::User, &out, root_for(RunScope::User, probe))
}

/// Enumerate every supervisor scope reachable on this host. On a systemd host
/// that is BOTH `systemctl --user` and system scope (the cuphead topology); on
/// a mac the single launchd user domain.
pub fn scan_all(probe: &Probe) -> Vec<ScopeScan> {
    if probe.has_systemctl {
        vec![
            scan_systemd(RunScope::User, true, probe),
            scan_systemd(RunScope::System, false, probe),
        ]
    } else if probe.has_launchctl {
        vec![scan_launchd(probe)]
    } else {
        Vec::new()
    }
}

/// The scope THIS process would install into: system when running as root,
/// user otherwise. Matches [`crate::detect`]'s root-vs-user rule.
fn current_scope(probe: &Probe) -> RunScope {
    if probe.euid == Some(0) {
        RunScope::System
    } else {
        RunScope::User
    }
}

/// Append an ambient event to the node's stream (best-effort). Resolves the
/// path the same way `src/node_mode.rs` does: `$NODE_AMBIENT`, else
/// `$CHUMP_STATE_DIR/ambient.jsonl`, else `$HOME/.chump/ambient.jsonl`.
fn emit_ambient(kind: &str, extra: &str) {
    let path = std::env::var("NODE_AMBIENT").unwrap_or_else(|_| {
        let dir = std::env::var("CHUMP_STATE_DIR").unwrap_or_else(|_| {
            let home = std::env::var("HOME").unwrap_or_default();
            format!("{home}/.chump")
        });
        format!("{dir}/ambient.jsonl")
    });
    if let Some(parent) = Path::new(&path).parent() {
        if !parent.exists() {
            return; // don't create a stray tree just to log
        }
    }
    let ts = iso_now();
    let line = if extra.is_empty() {
        format!("{{\"ts\":\"{ts}\",\"kind\":\"{kind}\"}}\n")
    } else {
        format!("{{\"ts\":\"{ts}\",\"kind\":\"{kind}\",{extra}}}\n")
    };
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

fn iso_now() -> String {
    // chrono is already a workspace dep; keep the format identical to node_mode.
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

fn scope_label(s: RunScope) -> &'static str {
    s.as_str()
}

/// Enumerate both scopes and print per-scope work-organ counts for the pause /
/// resume verbs. Returns the number of work organs active in a scope OTHER than
/// this process's own — the organs a scope-local pause cannot reach.
/// `chump node pause` refuses to report PAUSED while this is > 0 (the cuphead
/// second-scope defect); a single-scope node's own organs drain on their next
/// tick and do not block the report.
pub fn report_scopes(probe: &Probe) -> usize {
    let scans = scan_all(probe);
    for s in &scans {
        let active = s.active_work_organs();
        println!(
            "  {:<7} scope: {} work organ(s) active, {} enabled unit(s), root={}",
            scope_label(s.scope),
            active.len(),
            s.enabled_units().len(),
            s.root.as_deref().unwrap_or("-"),
        );
        for name in &active {
            println!("           ↳ active work organ: {name}");
        }
    }
    work_active_in_other_scopes(&scans, current_scope(probe))
}

/// `chump node scopes [--json] [--install-guard]`.
pub fn run_scopes(args: &[String], probe: &Probe) -> i32 {
    let mut json = false;
    let mut install_guard = false;
    for a in args {
        match a.as_str() {
            "--json" => json = true,
            "--install-guard" => install_guard = true,
            "-h" | "--help" => {
                println!(
                    "Usage: chump node scopes [--json] [--install-guard]\n\
                     Enumerate chump work organs in BOTH systemd scopes (--user + system)\n\
                     or the mac launchd user domain. Exits 3 on a two-scope node.\n\
                     --install-guard: refuse (exit 3) if the OTHER scope already has an install."
                );
                return 0;
            }
            other => {
                eprintln!("chump node scopes: unknown arg: {other}");
                return 2;
            }
        }
    }

    let scans = scan_all(probe);

    if install_guard {
        return install_guard_check(&scans, probe);
    }

    let two_scope = two_scope_installed(&scans);

    if json {
        let scopes_json: Vec<serde_json::Value> = scans
            .iter()
            .map(|s| {
                serde_json::json!({
                    "scope": scope_label(s.scope),
                    "root": s.root,
                    "active_work_organs": s.active_work_organs(),
                    "enabled_units": s.enabled_units().len(),
                    "installed": s.is_installed(),
                })
            })
            .collect();
        let v = serde_json::json!({
            "two_scope": two_scope,
            "work_active_total": any_work_active(&scans),
            "scopes": scopes_json,
        });
        println!("{v}");
    } else {
        println!("=== chump node scopes (RESILIENT-1615) ===");
        for s in &scans {
            let active = s.active_work_organs();
            println!(
                "  {:<7} scope: {} work organ(s) active, {} enabled unit(s), root={}",
                scope_label(s.scope),
                active.len(),
                s.enabled_units().len(),
                s.root.as_deref().unwrap_or("-"),
            );
            for name in &active {
                println!("           ↳ active work organ: {name}");
            }
        }
        if two_scope {
            let roots: Vec<String> = scans
                .iter()
                .filter(|s| s.is_installed())
                .map(|s| {
                    format!(
                        "{}={}",
                        scope_label(s.scope),
                        s.root.as_deref().unwrap_or("(units only)")
                    )
                })
                .collect();
            eprintln!(
                "\n  ✗ TWO-SCOPE NODE: a chump install exists in more than one scope [{}].\n    \
                 A converged node must have exactly ONE install in ONE scope. Retire the\n    \
                 second install (disable its units + remove its root) before resuming.",
                roots.join(", ")
            );
        }
    }

    if two_scope {
        3
    } else {
        0
    }
}

/// Installer/converge pre-flight: refuse when the OTHER scope already has an
/// install. Emits `kind=node_second_scope_refused` and returns 3; returns 0
/// (allow) when this is the only scope with an install.
fn install_guard_check(scans: &[ScopeScan], probe: &Probe) -> i32 {
    let this = current_scope(probe);
    let other = scans.iter().find(|s| s.scope != this && s.is_installed());
    match other {
        Some(s) => {
            let this_root = root_for(this, probe).unwrap_or_else(|| "(none)".to_string());
            let other_root = s.root.clone().unwrap_or_else(|| "(units only)".to_string());
            emit_ambient(
                "node_second_scope_refused",
                &format!(
                    "\"this_scope\":\"{}\",\"this_root\":\"{}\",\"other_scope\":\"{}\",\"other_root\":\"{}\",\"other_enabled\":{}",
                    scope_label(this),
                    crate::scopes::json_escape(&this_root),
                    scope_label(s.scope),
                    crate::scopes::json_escape(&other_root),
                    s.enabled_units().len(),
                ),
            );
            eprintln!(
                "\n  ✗ REFUSING INSTALL: a chump install already exists in the {} scope \
                 (root={}, {} enabled unit(s)).\n    This process would install into the {} scope \
                 (root={}) — a SECOND scope on a node that already has one.\n    That is the \
                 cuphead two-fleet defect (RESILIENT-1615): retire the other install first.",
                scope_label(s.scope),
                other_root,
                s.enabled_units().len(),
                scope_label(this),
                this_root,
            );
            3
        }
        None => 0,
    }
}
