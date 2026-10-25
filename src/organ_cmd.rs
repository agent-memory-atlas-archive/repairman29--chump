//! RESILIENT-1692: `chump organ pause <unit> [--reason <text>]` and
//! `chump organ resume <unit>`.
//!
//! Manages `~/.chump/paused-timers.txt` (or `$CHUMP_PAUSED_TIMERS_FILE` /
//! `$CHUMP_STATE_DIR/paused-timers.txt`) and stops/disables or enables/starts
//! the target systemd unit so `organ-reconcile.sh` never revives an
//! operator-paused timer or service.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Normalize a unit name (`chump-foo.timer`, `chump-foo.service`, `chump-foo`,
/// or `foo`) to its canonical base without `.timer`/`.service` and without a
/// leading `chump-` prefix so `.timer`/`.service` sibling names match.
pub fn normalize_organ_key(raw: &str) -> String {
    let trimmed = raw.trim();
    let base = trimmed
        .strip_suffix(".service")
        .or_else(|| trimmed.strip_suffix(".timer"))
        .unwrap_or(trimmed);
    base.strip_prefix("chump-").unwrap_or(base).to_string()
}

/// Extract the unit token from a single line of `paused-timers.txt`, stripping
/// trailing `# ...` comments and whitespace.
pub fn parse_paused_line_unit(line: &str) -> Option<&str> {
    let before_comment = line.split('#').next().unwrap_or("").trim();
    if before_comment.is_empty() {
        return None;
    }
    before_comment.split_whitespace().next()
}

/// True if `paused_file` lists `unit` (matching across `.timer`/`.service`/bare
/// variants and ignoring trailing `# <ts> <reason>` comments).
pub fn is_organ_paused_in_file(paused_file: &Path, unit: &str) -> bool {
    let Ok(body) = fs::read_to_string(paused_file) else {
        return false;
    };
    let want = normalize_organ_key(unit);
    if want.is_empty() {
        return false;
    }
    body.lines()
        .filter_map(parse_paused_line_unit)
        .any(|entry| normalize_organ_key(entry) == want)
}

/// Resolve the path to `paused-timers.txt`.
pub fn resolve_paused_timers_file() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_PAUSED_TIMERS_FILE") {
        if !p.trim().is_empty() {
            return PathBuf::from(p.trim());
        }
    }
    if let Ok(sd) = std::env::var("CHUMP_STATE_DIR") {
        if !sd.trim().is_empty() {
            return PathBuf::from(sd.trim()).join("paused-timers.txt");
        }
    }
    let home = std::env::var("CHUMP_HOME")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .or_else(|| std::env::var("HOME").ok().filter(|s| !s.trim().is_empty()))
        .unwrap_or_else(|| "/tmp".to_string());
    PathBuf::from(home).join(".chump/paused-timers.txt")
}

/// Record `unit` as paused in `paused_file` with `# <iso-ts> <reason>`,
/// replacing any prior line for the same organ.
pub fn pause_organ_in_file(
    paused_file: &Path,
    unit: &str,
    reason: &str,
    iso_ts: &str,
) -> std::io::Result<()> {
    if let Some(parent) = paused_file.parent() {
        fs::create_dir_all(parent)?;
    }
    let want = normalize_organ_key(unit);
    let existing = fs::read_to_string(paused_file).unwrap_or_default();
    let mut kept: Vec<String> = existing
        .lines()
        .filter(|line| match parse_paused_line_unit(line) {
            Some(entry) => normalize_organ_key(entry) != want,
            None => true,
        })
        .map(str::to_string)
        .collect();
    let clean_reason = reason.replace(['\r', '\n'], " ");
    let clean_reason = clean_reason.trim();
    let clean_reason = if clean_reason.is_empty() {
        "operator paused"
    } else {
        clean_reason
    };
    kept.push(format!("{} # {} {}", unit.trim(), iso_ts, clean_reason));
    let mut out = kept.join("\n");
    out.push('\n');
    fs::write(paused_file, out)
}

/// Remove `unit` (and any `.timer`/`.service`/bare equivalent) from
/// `paused_file`. Returns `true` if at least one entry was removed.
pub fn resume_organ_in_file(paused_file: &Path, unit: &str) -> std::io::Result<bool> {
    let Ok(existing) = fs::read_to_string(paused_file) else {
        return Ok(false);
    };
    let want = normalize_organ_key(unit);
    let mut removed = false;
    let kept: Vec<&str> = existing
        .lines()
        .filter(|line| match parse_paused_line_unit(line) {
            Some(entry) if normalize_organ_key(entry) == want => {
                removed = true;
                false
            }
            _ => true,
        })
        .collect();
    let mut out = kept.join("\n");
    if !out.is_empty() {
        out.push('\n');
    }
    fs::write(paused_file, out)?;
    Ok(removed)
}

fn systemctl_bin() -> String {
    std::env::var("CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| "systemctl".to_string())
}

fn run_systemctl_action(action: &str, unit: &str) {
    let bin = systemctl_bin();
    let _ = Command::new(&bin).args([action, "--now", unit]).status();
}

pub fn print_usage() {
    println!("Usage: chump organ pause <unit> [--reason \"<text>\"]");
    println!("       chump organ resume <unit>");
    println!();
    println!("Pause or resume a systemd timer/service organ via ~/.chump/paused-timers.txt");
    println!("so organ-reconcile.sh respects operator stops across deploy cycles.");
}

pub fn run(args: &[String]) -> i32 {
    let subcmd = args.first().map(String::as_str).unwrap_or("help");
    if matches!(subcmd, "help" | "--help" | "-h") {
        print_usage();
        return 0;
    }

    match subcmd {
        "pause" => {
            if args
                .iter()
                .skip(1)
                .any(|a| matches!(a.as_str(), "--help" | "-h" | "help"))
            {
                print_usage();
                return 0;
            }
            let Some(unit) = args.get(1).filter(|s| !s.starts_with('-')).cloned() else {
                eprintln!("chump organ pause: <unit> is required");
                print_usage();
                return 2;
            };
            let mut reason = "operator paused".to_string();
            let mut i = 2;
            while i < args.len() {
                match args[i].as_str() {
                    "--reason" => {
                        if let Some(r) = args.get(i + 1) {
                            reason = r.clone();
                            i += 2;
                        } else {
                            eprintln!("chump organ pause: --reason requires a value");
                            return 2;
                        }
                    }
                    other => {
                        eprintln!("chump organ pause: unknown flag '{other}'");
                        return 2;
                    }
                }
            }
            let paused_file = resolve_paused_timers_file();
            let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
            if let Err(e) = pause_organ_in_file(&paused_file, &unit, &reason, &ts) {
                eprintln!(
                    "chump organ pause: failed to write {}: {e}",
                    paused_file.display()
                );
                return 1;
            }
            run_systemctl_action("disable", &unit);
            println!(
                "[organ] paused {} (recorded in {} # {} {})",
                unit,
                paused_file.display(),
                ts,
                reason
            );
            0
        }
        "resume" => {
            if args
                .iter()
                .skip(1)
                .any(|a| matches!(a.as_str(), "--help" | "-h" | "help"))
            {
                print_usage();
                return 0;
            }
            let Some(unit) = args.get(1).filter(|s| !s.starts_with('-')).cloned() else {
                eprintln!("chump organ resume: <unit> is required");
                print_usage();
                return 2;
            };
            let paused_file = resolve_paused_timers_file();
            match resume_organ_in_file(&paused_file, &unit) {
                Ok(_) => {
                    run_systemctl_action("enable", &unit);
                    println!(
                        "[organ] resumed {} (removed from {})",
                        unit,
                        paused_file.display()
                    );
                    0
                }
                Err(e) => {
                    eprintln!(
                        "chump organ resume: failed to update {}: {e}",
                        paused_file.display()
                    );
                    1
                }
            }
        }
        other => {
            eprintln!("chump organ: unknown subcommand '{other}'");
            print_usage();
            2
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pause_and_resume_roundtrip_with_comments_and_suffixes_resilient_1692() {
        let tmp = tempfile::tempdir().unwrap();
        let pf = tmp.path().join("paused-timers.txt");

        pause_organ_in_file(
            &pf,
            "chump-backlog-governor.timer",
            "debugging token burn",
            "2026-10-25T10:00:00Z",
        )
        .unwrap();

        let body = fs::read_to_string(&pf).unwrap();
        assert_eq!(
            body,
            "chump-backlog-governor.timer # 2026-10-25T10:00:00Z debugging token burn\n"
        );

        // Matches exact unit, .service sibling, bare chump-* name, and bare name.
        assert!(is_organ_paused_in_file(&pf, "chump-backlog-governor.timer"));
        assert!(is_organ_paused_in_file(
            &pf,
            "chump-backlog-governor.service"
        ));
        assert!(is_organ_paused_in_file(&pf, "chump-backlog-governor"));
        assert!(is_organ_paused_in_file(&pf, "backlog-governor"));
        assert!(!is_organ_paused_in_file(&pf, "chump-farmer.timer"));

        // Resume via sibling/bare name removes the commented entry cleanly.
        let removed = resume_organ_in_file(&pf, "chump-backlog-governor.service").unwrap();
        assert!(removed);
        assert!(!is_organ_paused_in_file(
            &pf,
            "chump-backlog-governor.timer"
        ));
    }
}
