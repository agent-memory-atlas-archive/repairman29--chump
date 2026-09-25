//! `chump cron health` (META-110/INFRA-2046) — audits every chump-managed
//! plist (launchd) / timer unit (systemd) for the failure classes the
//! scheduling layer keeps re-discovering by hand: missing schedule keys
//! (INFRA-1929 class, fires once and never again), unloaded/inactive
//! units, and stale last-run timestamps. One JSON record per managed
//! service with `kind=chump_cron_managed` so the output composes with the
//! rest of the ambient/ops tooling.

use crate::backend::{Backend, SENTINEL};
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::process::Command;

/// One managed plist/unit's health snapshot.
#[derive(Debug, Clone, Serialize)]
pub struct CronHealthEntry {
    pub kind: &'static str,
    pub name: String,
    pub label: String,
    pub backend: &'static str,
    pub installed: bool,
    pub has_schedule: bool,
    pub loaded: bool,
    pub last_run: Option<String>,
    pub last_exit_status: Option<String>,
    pub warnings: Vec<String>,
}

impl CronHealthEntry {
    pub fn is_healthy(&self) -> bool {
        self.warnings.is_empty()
    }
}

fn home_dir() -> String {
    std::env::var("HOME").unwrap_or_else(|_| "/root".to_string())
}

/// Scan for chump-managed cron entries and report health for each,
/// auto-detecting backend from the platform (override via
/// `CHUMP_CRON_BACKEND`).
pub fn scan() -> Vec<CronHealthEntry> {
    match Backend::detect() {
        Backend::Launchd => scan_launchd(&home_dir()),
        Backend::Systemd => scan_systemd(&home_dir()),
    }
}

fn scan_launchd(home: &str) -> Vec<CronHealthEntry> {
    let dir = PathBuf::from(home).join("Library/LaunchAgents");
    let mut out = Vec::new();
    let entries = match std::fs::read_dir(&dir) {
        Ok(e) => e,
        Err(_) => return out,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let fname = match path.file_name().and_then(|f| f.to_str()) {
            Some(f) => f.to_string(),
            None => continue,
        };
        if !(fname.starts_with("com.chump.") && fname.ends_with(".plist")) {
            continue;
        }
        let content = std::fs::read_to_string(&path).unwrap_or_default();
        if !content.contains(SENTINEL) {
            continue; // operator-owned plist reusing our label prefix; not ours.
        }
        let label = fname.trim_end_matches(".plist").to_string();
        let name = label.trim_start_matches("com.chump.").to_string();
        out.push(health_from_launchd_plist(&label, &name, &path, &content));
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

fn health_from_launchd_plist(
    label: &str,
    name: &str,
    path: &Path,
    content: &str,
) -> CronHealthEntry {
    let has_schedule =
        content.contains("StartInterval") || content.contains("StartCalendarInterval");
    let uid = Command::new("id")
        .arg("-u")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "501".to_string());
    let print_out = Command::new("launchctl")
        .arg("print")
        .arg(format!("gui/{uid}/{label}"))
        .output();
    let (loaded, print_text) = match print_out {
        Ok(o) => (
            o.status.success(),
            String::from_utf8_lossy(&o.stdout).to_string(),
        ),
        Err(_) => (false, String::new()),
    };
    let last_exit_status = print_text
        .lines()
        .find(|l| l.trim_start().starts_with("last exit code"))
        .map(|l| l.trim().to_string());

    let mut warnings = Vec::new();
    if !path.exists() {
        warnings.push("plist missing from disk".to_string());
    }
    if !has_schedule {
        warnings.push(
            "missing StartInterval/StartCalendarInterval — will only fire once (INFRA-1929 class)"
                .to_string(),
        );
    }
    if !loaded {
        warnings.push("not loaded in launchd (launchctl print failed)".to_string());
    }

    CronHealthEntry {
        kind: "chump_cron_managed",
        name: name.to_string(),
        label: label.to_string(),
        backend: "launchd",
        installed: path.exists(),
        has_schedule,
        loaded,
        last_run: None,
        last_exit_status,
        warnings,
    }
}

fn scan_systemd(home: &str) -> Vec<CronHealthEntry> {
    let dir = PathBuf::from(home).join(".config/systemd/user");
    let mut out = Vec::new();
    let entries = match std::fs::read_dir(&dir) {
        Ok(e) => e,
        Err(_) => return out,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let fname = match path.file_name().and_then(|f| f.to_str()) {
            Some(f) => f.to_string(),
            None => continue,
        };
        if !(fname.starts_with("chump-") && fname.ends_with(".timer")) {
            continue;
        }
        let content = std::fs::read_to_string(&path).unwrap_or_default();
        if !content.contains(SENTINEL) {
            continue;
        }
        let timer_unit = fname.clone();
        let name = fname
            .trim_start_matches("chump-")
            .trim_end_matches(".timer")
            .to_string();
        let service_unit = format!("chump-{name}.service");
        out.push(health_from_systemd_timer(
            &name,
            &timer_unit,
            &service_unit,
            &path,
            &content,
        ));
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

fn systemctl_show(unit: &str, property: &str) -> Option<String> {
    let out = Command::new("systemctl")
        .args(["--user", "show", unit, "--property", property, "--value"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let v = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if v.is_empty() {
        None
    } else {
        Some(v)
    }
}

fn is_stale(last_run: &Option<String>) -> bool {
    let ts = match last_run {
        Some(t) if !t.is_empty() && t != "n/a" => t,
        _ => return false,
    };
    let epoch = Command::new("date")
        .args(["-d", ts, "+%s"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| s.trim().parse::<i64>().ok());
    let now = Command::new("date")
        .arg("+%s")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| s.trim().parse::<i64>().ok());
    match (epoch, now) {
        (Some(e), Some(n)) => (n - e) > 86_400, // > 24h since last trigger
        _ => false,
    }
}

fn health_from_systemd_timer(
    name: &str,
    timer_unit: &str,
    service_unit: &str,
    path: &Path,
    content: &str,
) -> CronHealthEntry {
    let has_schedule = content.contains("OnCalendar") || content.contains("OnUnitActiveSec");
    let active = systemctl_show(timer_unit, "ActiveState");
    let loaded = active.as_deref() == Some("active");
    let last_run = systemctl_show(service_unit, "ExecMainStartTimestamp");
    let last_exit_status = systemctl_show(service_unit, "ExecMainStatus");

    let mut warnings = Vec::new();
    if !path.exists() {
        warnings.push("timer unit missing from disk".to_string());
    }
    if !has_schedule {
        warnings.push(
            "missing OnCalendar/OnUnitActiveSec — will only fire once (INFRA-1929 class)"
                .to_string(),
        );
    }
    if !loaded {
        warnings.push(format!(
            "timer not active (ActiveState={})",
            active.as_deref().unwrap_or("unknown")
        ));
    }
    if let Some(status) = &last_exit_status {
        if status != "0" {
            warnings.push(format!(
                "last run exited non-zero (ExecMainStatus={status})"
            ));
        }
    }
    if is_stale(&last_run) {
        warnings.push(format!(
            "stale: no run in >24h (last_run={})",
            last_run.as_deref().unwrap_or("unknown")
        ));
    }

    CronHealthEntry {
        kind: "chump_cron_managed",
        name: name.to_string(),
        label: service_unit.to_string(),
        backend: "systemd",
        installed: path.exists(),
        has_schedule,
        loaded,
        last_run,
        last_exit_status,
        warnings,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn managed_timer_content() -> String {
        format!(
            "# {SENTINEL}\n[Unit]\nDescription=test\n\n[Timer]\nOnUnitActiveSec=300s\n\n[Install]\nWantedBy=timers.target\n"
        )
    }

    #[test]
    fn scan_systemd_skips_non_chump_files() {
        let home = tempdir().unwrap();
        let dir = home.path().join(".config/systemd/user");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("other-thing.timer"), "not ours").unwrap();
        let out = scan_systemd(home.path().to_str().unwrap());
        assert!(out.is_empty());
    }

    #[test]
    fn scan_systemd_skips_unmanaged_chump_prefixed_file() {
        let home = tempdir().unwrap();
        let dir = home.path().join(".config/systemd/user");
        std::fs::create_dir_all(&dir).unwrap();
        // Same name prefix but no sentinel — not chump-cron managed.
        std::fs::write(dir.join("chump-foo.timer"), "[Timer]\nOnCalendar=daily\n").unwrap();
        let out = scan_systemd(home.path().to_str().unwrap());
        assert!(out.is_empty());
    }

    #[test]
    fn scan_systemd_finds_managed_timer_and_flags_missing_schedule() {
        let home = tempdir().unwrap();
        let dir = home.path().join(".config/systemd/user");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("chump-heartbeat.timer"),
            format!("# {SENTINEL}\n[Timer]\nPersistent=true\n"),
        )
        .unwrap();
        let out = scan_systemd(home.path().to_str().unwrap());
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].name, "heartbeat");
        assert_eq!(out[0].kind, "chump_cron_managed");
        assert!(!out[0].has_schedule);
        assert!(out[0].warnings.iter().any(|w| w.contains("INFRA-1929")));
        assert!(!out[0].is_healthy());
    }

    #[test]
    fn scan_systemd_managed_timer_with_schedule_has_no_schedule_warning() {
        let home = tempdir().unwrap();
        let dir = home.path().join(".config/systemd/user");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("chump-gardener.timer"), managed_timer_content()).unwrap();
        let out = scan_systemd(home.path().to_str().unwrap());
        assert_eq!(out.len(), 1);
        assert!(out[0].has_schedule);
        assert!(!out[0].warnings.iter().any(|w| w.contains("INFRA-1929")));
    }

    #[test]
    fn empty_dir_yields_no_entries() {
        let home = tempdir().unwrap();
        let out = scan_systemd(home.path().to_str().unwrap());
        assert!(out.is_empty());
        let out2 = scan_launchd(home.path().to_str().unwrap());
        assert!(out2.is_empty());
    }
}
