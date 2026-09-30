//! `chump cron` plist/unit discovery + state parser backend (INFRA-7955,
//! INFRA-2046 slice). Scans the platform scheduler (launchd plists /
//! systemd user timers) for `com.chump.*`-labeled schedules, extracts the
//! keys `chump cron list`/`chump cron health` need (Label, Program /
//! ProgramArguments, Description, StartInterval / StartCalendarInterval),
//! and determines each schedule's status: loaded, unloaded, or missing
//! (registered in `REQUIRED_DAEMONS` but absent from disk).

use crate::backend::{Backend, SENTINEL};
use serde::Serialize;
use std::path::PathBuf;
use std::process::Command;

/// Whether a discovered schedule is actually running per the OS scheduler,
/// present-but-inactive, or expected (per `REQUIRED_DAEMONS`) yet absent
/// from disk entirely.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ScheduleStatus {
    Loaded,
    Unloaded,
    Missing,
}

/// One discovered `com.chump.*` schedule with its parsed plist/unit keys.
#[derive(Debug, Clone, Serialize)]
pub struct DiscoveredSchedule {
    pub label: String,
    pub program: Vec<String>,
    pub description: Option<String>,
    pub has_start_interval: bool,
    pub start_interval_secs: Option<u64>,
    pub has_start_calendar_interval: bool,
    pub status: ScheduleStatus,
    pub backend: &'static str,
}

fn home_dir() -> String {
    std::env::var("HOME").unwrap_or_else(|_| "/root".to_string())
}

/// Discover every chump-managed schedule, auto-detecting backend from the
/// platform (override via `CHUMP_CRON_BACKEND`).
pub fn discover() -> Vec<DiscoveredSchedule> {
    match Backend::detect() {
        Backend::Launchd => discover_launchd(&home_dir()),
        Backend::Systemd => discover_systemd(&home_dir()),
    }
}

// ── launchd ──────────────────────────────────────────────────────────────

pub fn discover_launchd(home: &str) -> Vec<DiscoveredSchedule> {
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
        let fallback_label = fname.trim_end_matches(".plist").to_string();
        out.push(parse_launchd_plist(&fallback_label, &content));
    }
    out.sort_by(|a, b| a.label.cmp(&b.label));
    out
}

fn parse_launchd_plist(fallback_label: &str, content: &str) -> DiscoveredSchedule {
    let label = extract_key_string(content, "Label").unwrap_or_else(|| fallback_label.to_string());
    let program = extract_program_arguments(content);
    let description =
        extract_description_comment(content).or_else(|| extract_key_string(content, "Description"));
    let has_start_interval = content.contains("<key>StartInterval</key>");
    let start_interval_secs = extract_key_integer(content, "StartInterval");
    let has_start_calendar_interval = content.contains("<key>StartCalendarInterval</key>");

    let status = if launchctl_loaded(&label) {
        ScheduleStatus::Loaded
    } else {
        ScheduleStatus::Unloaded
    };

    DiscoveredSchedule {
        label,
        program,
        description,
        has_start_interval,
        start_interval_secs,
        has_start_calendar_interval,
        status,
        backend: "launchd",
    }
}

fn launchctl_loaded(label: &str) -> bool {
    let uid = Command::new("id")
        .arg("-u")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "501".to_string());
    Command::new("launchctl")
        .arg("print")
        .arg(format!("gui/{uid}/{label}"))
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

// ── systemd ──────────────────────────────────────────────────────────────

pub fn discover_systemd(home: &str) -> Vec<DiscoveredSchedule> {
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
        let timer_content = std::fs::read_to_string(&path).unwrap_or_default();
        if !timer_content.contains(SENTINEL) {
            continue;
        }
        let name = fname
            .trim_start_matches("chump-")
            .trim_end_matches(".timer")
            .to_string();
        let service_path = dir.join(format!("chump-{name}.service"));
        let service_content = std::fs::read_to_string(&service_path).unwrap_or_default();
        out.push(parse_systemd_timer(&name, &timer_content, &service_content));
    }
    out.sort_by(|a, b| a.label.cmp(&b.label));
    out
}

fn parse_systemd_timer(
    name: &str,
    timer_content: &str,
    service_content: &str,
) -> DiscoveredSchedule {
    let description = extract_ini_value(service_content, "Description")
        .or_else(|| extract_ini_value(timer_content, "Description"));
    let program = extract_ini_value(service_content, "ExecStart")
        .map(|s| crate::spec::split_argv(&s).unwrap_or_else(|_| vec![s]))
        .unwrap_or_default();
    let has_start_interval = timer_content.contains("OnUnitActiveSec");
    let start_interval_secs = extract_ini_value(timer_content, "OnUnitActiveSec")
        .and_then(|v| v.trim_end_matches('s').parse().ok());
    let has_start_calendar_interval = timer_content.contains("OnCalendar");

    let active = systemctl_show(&format!("chump-{name}.timer"), "ActiveState");
    let status = match active.as_deref() {
        Some("active") => ScheduleStatus::Loaded,
        Some(_) => ScheduleStatus::Unloaded,
        None => ScheduleStatus::Unloaded,
    };

    DiscoveredSchedule {
        label: format!("chump-{name}"),
        program,
        description,
        has_start_interval,
        start_interval_secs,
        has_start_calendar_interval,
        status,
        backend: "systemd",
    }
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

fn extract_ini_value(content: &str, key: &str) -> Option<String> {
    let prefix = format!("{key}=");
    content.lines().find_map(|l| {
        l.strip_prefix(prefix.as_str())
            .map(|v| v.trim().to_string())
    })
}

// ── required-daemons cross-reference (status=missing) ──────────────────────

/// Cross-reference `REQUIRED_DAEMONS` entries in
/// `scripts/setup/chump-fleet-bootstrap.sh` against what's actually on
/// disk, returning a synthetic `DiscoveredSchedule` with
/// `status: Missing` for each expected `com.chump.*` label that has no
/// plist/unit installed. `discovered` should be the result of
/// `discover_launchd`/`discover_systemd`/`discover`.
pub fn missing_required_daemons(
    bootstrap_script: &str,
    discovered: &[DiscoveredSchedule],
) -> Vec<DiscoveredSchedule> {
    let present: std::collections::HashSet<&str> =
        discovered.iter().map(|d| d.label.as_str()).collect();
    let backend = Backend::detect().as_str();
    required_daemon_labels(bootstrap_script)
        .into_iter()
        .filter(|label| !present.contains(label.as_str()))
        .map(|label| DiscoveredSchedule {
            label,
            program: Vec::new(),
            description: None,
            has_start_interval: false,
            start_interval_secs: None,
            has_start_calendar_interval: false,
            status: ScheduleStatus::Missing,
            backend,
        })
        .collect()
}

fn required_daemon_labels(bootstrap_script: &str) -> Vec<String> {
    bootstrap_script
        .lines()
        .map(str::trim)
        .filter(|l| l.starts_with("\"com.chump."))
        .filter_map(|l| {
            let inner = l.trim_matches(|c| c == '"' || c == ',');
            inner.split('|').next().map(str::to_string)
        })
        .collect()
}

// ── plist XML key extraction ────────────────────────────────────────────

fn extract_key_string(content: &str, key: &str) -> Option<String> {
    let marker = format!("<key>{key}</key>");
    let idx = content.find(&marker)?;
    let after = &content[idx + marker.len()..];
    let start = after.find("<string>")? + "<string>".len();
    let end = after[start..].find("</string>")? + start;
    Some(xml_unescape(after[start..end].trim()))
}

fn extract_key_integer(content: &str, key: &str) -> Option<u64> {
    let marker = format!("<key>{key}</key>");
    let idx = content.find(&marker)?;
    let after = &content[idx + marker.len()..];
    let start = after.find("<integer>")? + "<integer>".len();
    let end = after[start..].find("</integer>")? + start;
    after[start..end].trim().parse().ok()
}

fn extract_program_arguments(content: &str) -> Vec<String> {
    if let Some(prog) = extract_key_string(content, "Program") {
        return vec![prog];
    }
    let marker = "<key>ProgramArguments</key>";
    let Some(idx) = content.find(marker) else {
        return Vec::new();
    };
    let after = &content[idx + marker.len()..];
    let Some(arr_start) = after.find("<array>") else {
        return Vec::new();
    };
    let Some(arr_end) = after.find("</array>") else {
        return Vec::new();
    };
    if arr_end < arr_start {
        return Vec::new();
    }
    let body = &after[arr_start + "<array>".len()..arr_end];
    let mut out = Vec::new();
    let mut rest = body;
    while let Some(s) = rest.find("<string>") {
        let after_s = &rest[s + "<string>".len()..];
        let Some(e) = after_s.find("</string>") else {
            break;
        };
        out.push(xml_unescape(after_s[..e].trim()));
        rest = &after_s[e + "</string>".len()..];
    }
    out
}

fn extract_description_comment(content: &str) -> Option<String> {
    let marker = "<!-- chump-cron-description: ";
    let idx = content.find(marker)?;
    let after = &content[idx + marker.len()..];
    let end = after.find(" -->")?;
    let val = after[..end].trim();
    if val.is_empty() {
        None
    } else {
        Some(xml_unescape(val))
    }
}

fn xml_unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::{render_launchd_plist, render_systemd_units, Schedule};
    use crate::cron_expr::CronSchedule;
    use crate::spec::{CronSpec, Scope};
    use tempfile::tempdir;

    fn sample_spec(schedule: Schedule) -> CronSpec {
        CronSpec {
            name: "test-daemon".into(),
            schedule,
            exec_argv: vec!["/bin/echo".into(), "hi there".into()],
            description: Some("a test daemon".into()),
            working_dir: None,
            env: Vec::new(),
            stdout_log: None,
            stderr_log: None,
            scope: Scope::User,
        }
    }

    #[test]
    fn parses_label_program_description_interval_from_rendered_plist() {
        let spec = sample_spec(Schedule::Interval(300));
        let xml = render_launchd_plist(&spec);
        let parsed = parse_launchd_plist("fallback", &xml);
        assert_eq!(parsed.label, "com.chump.test-daemon");
        assert_eq!(parsed.program, vec!["/bin/echo", "hi there"]);
        assert_eq!(parsed.description.as_deref(), Some("a test daemon"));
        assert!(parsed.has_start_interval);
        assert_eq!(parsed.start_interval_secs, Some(300));
        assert!(!parsed.has_start_calendar_interval);
    }

    #[test]
    fn parses_calendar_interval_flag() {
        let spec = sample_spec(Schedule::Cron(CronSchedule::parse("0 9 * * *").unwrap()));
        let xml = render_launchd_plist(&spec);
        let parsed = parse_launchd_plist("fallback", &xml);
        assert!(parsed.has_start_calendar_interval);
        assert!(!parsed.has_start_interval);
        assert_eq!(parsed.start_interval_secs, None);
    }

    #[test]
    fn falls_back_to_filename_label_when_key_absent() {
        let parsed = parse_launchd_plist("com.chump.fallback-name", "<plist></plist>");
        assert_eq!(parsed.label, "com.chump.fallback-name");
        assert!(parsed.program.is_empty());
        assert!(parsed.description.is_none());
    }

    #[test]
    fn discover_launchd_skips_non_chump_and_unmanaged_files() {
        let home = tempdir().unwrap();
        let dir = home.path().join("Library/LaunchAgents");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("com.other.thing.plist"), "not ours").unwrap();
        std::fs::write(
            dir.join("com.chump.unmanaged.plist"),
            "<plist><key>Label</key><string>com.chump.unmanaged</string></plist>",
        )
        .unwrap();
        let out = discover_launchd(home.path().to_str().unwrap());
        assert!(out.is_empty());
    }

    #[test]
    fn discover_launchd_finds_managed_plist() {
        let home = tempdir().unwrap();
        let dir = home.path().join("Library/LaunchAgents");
        std::fs::create_dir_all(&dir).unwrap();
        let spec = sample_spec(Schedule::Interval(60));
        let xml = render_launchd_plist(&spec);
        std::fs::write(dir.join("com.chump.test-daemon.plist"), xml).unwrap();
        let out = discover_launchd(home.path().to_str().unwrap());
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].label, "com.chump.test-daemon");
        assert_eq!(out[0].status, ScheduleStatus::Unloaded); // launchctl print will fail for a non-loaded fake label
        assert_eq!(out[0].backend, "launchd");
    }

    #[test]
    fn discover_systemd_parses_execstart_and_description() {
        let home = tempdir().unwrap();
        let dir = home.path().join(".config/systemd/user");
        std::fs::create_dir_all(&dir).unwrap();
        let spec = sample_spec(Schedule::Interval(120));
        let (service, timer) = render_systemd_units(&spec);
        std::fs::write(dir.join("chump-test-daemon.service"), service).unwrap();
        std::fs::write(dir.join("chump-test-daemon.timer"), timer).unwrap();
        let out = discover_systemd(home.path().to_str().unwrap());
        assert_eq!(out.len(), 1);
        let entry = &out[0];
        assert_eq!(entry.label, "chump-test-daemon");
        assert_eq!(entry.program, vec!["/bin/echo", "hi there"]);
        assert_eq!(entry.description.as_deref(), Some("a test daemon"));
        assert!(entry.has_start_interval);
        assert_eq!(entry.start_interval_secs, Some(120));
        assert_eq!(entry.backend, "systemd");
    }

    #[test]
    fn discover_systemd_skips_unmanaged_timer() {
        let home = tempdir().unwrap();
        let dir = home.path().join(".config/systemd/user");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("chump-foo.timer"), "[Timer]\nOnCalendar=daily\n").unwrap();
        let out = discover_systemd(home.path().to_str().unwrap());
        assert!(out.is_empty());
    }

    #[test]
    fn missing_required_daemons_flags_absent_labels() {
        let bootstrap = r#"
REQUIRED_DAEMONS=(
    "com.chump.paramedic|scripts/setup/install-paramedic.sh"
    "com.chump.test-daemon|scripts/setup/install-test-daemon.sh"
)
"#;
        let discovered = vec![DiscoveredSchedule {
            label: "com.chump.test-daemon".to_string(),
            program: vec!["/bin/echo".to_string()],
            description: None,
            has_start_interval: true,
            start_interval_secs: Some(60),
            has_start_calendar_interval: false,
            status: ScheduleStatus::Loaded,
            backend: "launchd",
        }];
        let missing = missing_required_daemons(bootstrap, &discovered);
        assert_eq!(missing.len(), 1);
        assert_eq!(missing[0].label, "com.chump.paramedic");
        assert_eq!(missing[0].status, ScheduleStatus::Missing);
    }

    #[test]
    fn missing_required_daemons_empty_when_all_present() {
        let bootstrap = r#""com.chump.paramedic|scripts/setup/install-paramedic.sh""#;
        let discovered = vec![DiscoveredSchedule {
            label: "com.chump.paramedic".to_string(),
            program: Vec::new(),
            description: None,
            has_start_interval: false,
            start_interval_secs: None,
            has_start_calendar_interval: false,
            status: ScheduleStatus::Loaded,
            backend: "launchd",
        }];
        assert!(missing_required_daemons(bootstrap, &discovered).is_empty());
    }
}
