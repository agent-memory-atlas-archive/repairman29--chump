//! `chump cron` — declarative cron-expr → launchd plist (macOS) / systemd
//! user timer (Linux) generator. Idempotent install/uninstall/status.
//! Never depends on Claude Code or any specific agent session being alive
//! (INFRA-2057).

pub mod backend;
pub mod cron_expr;
pub mod health;
pub mod health_sentinel;
pub mod ops;
pub mod spec;

use anyhow::{anyhow, Result};
use backend::{Backend, Schedule};
use cron_expr::{parse_interval_seconds, CronSchedule};
use spec::{split_argv, CronSpec, Scope};

const USAGE: &str = r#"Usage: chump cron <install|uninstall|status> [options]

  chump cron install --name NAME (--schedule CRON_EXPR | --interval Ns) --exec COMMAND
                      [--description TEXT] [--working-dir PATH] [--env KEY=VAL]...
                      [--stdout-log PATH] [--stderr-log PATH] [--scope user|system]

  chump cron uninstall --name NAME [--scope user|system]

  chump cron status --name NAME [--scope user|system]

  chump cron health [--json]

Backend is auto-detected from platform (macOS -> launchd, Linux -> systemd);
override with CHUMP_CRON_BACKEND=launchd|systemd.

Examples:
  chump cron install --name gap-gardener --schedule "0 */1 * * *" \
      --exec "/usr/local/bin/chump gap-gardener --sweep"
  chump cron install --name heartbeat --interval 300s --exec "/bin/true"
  chump cron uninstall --name gap-gardener
  chump cron health --json   # audit every chump-managed plist/unit (INFRA-2046)
"#;

pub fn run(args: &[String]) -> i32 {
    match run_inner(args) {
        Ok(code) => code,
        Err(e) => {
            eprintln!("chump cron: {e}");
            1
        }
    }
}

fn run_inner(args: &[String]) -> Result<i32> {
    let sub = args.first().map(String::as_str).unwrap_or("");
    if sub == "--help" || sub == "-h" || sub == "help" || sub.is_empty() {
        print!("{USAGE}");
        return Ok(0);
    }

    match sub {
        "install" => cmd_install(&args[1..]),
        "uninstall" => cmd_uninstall(&args[1..]),
        "status" => cmd_status(&args[1..]),
        "health" => cmd_health(&args[1..]),
        other => {
            eprintln!("chump cron: unknown subcommand '{other}'\n\n{USAGE}");
            Ok(1)
        }
    }
}

struct ParsedArgs {
    name: Option<String>,
    schedule: Option<String>,
    interval: Option<String>,
    exec: Option<String>,
    description: Option<String>,
    working_dir: Option<String>,
    env: Vec<(String, String)>,
    stdout_log: Option<String>,
    stderr_log: Option<String>,
    scope: Scope,
}

fn parse_flags(args: &[String]) -> Result<ParsedArgs> {
    let mut p = ParsedArgs {
        name: None,
        schedule: None,
        interval: None,
        exec: None,
        description: None,
        working_dir: None,
        env: Vec::new(),
        stdout_log: None,
        stderr_log: None,
        scope: Scope::User,
    };
    let mut i = 0;
    while i < args.len() {
        let need = |i: usize| -> Result<&String> {
            args.get(i + 1)
                .ok_or_else(|| anyhow!("{} needs a value", args[i]))
        };
        match args[i].as_str() {
            "--name" => {
                p.name = Some(need(i)?.clone());
                i += 2;
            }
            "--schedule" => {
                p.schedule = Some(need(i)?.clone());
                i += 2;
            }
            "--interval" => {
                p.interval = Some(need(i)?.clone());
                i += 2;
            }
            "--exec" => {
                p.exec = Some(need(i)?.clone());
                i += 2;
            }
            "--description" => {
                p.description = Some(need(i)?.clone());
                i += 2;
            }
            "--working-dir" => {
                p.working_dir = Some(need(i)?.clone());
                i += 2;
            }
            "--env" => {
                let kv = need(i)?;
                let (k, v) = kv
                    .split_once('=')
                    .ok_or_else(|| anyhow!("--env must be KEY=VAL (got '{kv}')"))?;
                p.env.push((k.to_string(), v.to_string()));
                i += 2;
            }
            "--stdout-log" => {
                p.stdout_log = Some(need(i)?.clone());
                i += 2;
            }
            "--stderr-log" => {
                p.stderr_log = Some(need(i)?.clone());
                i += 2;
            }
            "--scope" => {
                let v = need(i)?;
                p.scope = match v.as_str() {
                    "user" => Scope::User,
                    "system" => Scope::System,
                    other => {
                        return Err(anyhow!(
                            "--scope must be 'user' or 'system' (got '{other}')"
                        ))
                    }
                };
                i += 2;
            }
            other => return Err(anyhow!("unknown flag: {other}")),
        }
    }
    Ok(p)
}

fn build_spec(p: &ParsedArgs, require_exec: bool) -> Result<CronSpec> {
    let name = p
        .name
        .clone()
        .ok_or_else(|| anyhow!("--name is required"))?;
    CronSpec::validate_name(&name)?;

    let schedule = match (&p.schedule, &p.interval) {
        (Some(_), Some(_)) => {
            return Err(anyhow!("--schedule and --interval are mutually exclusive"))
        }
        (Some(expr), None) => Schedule::Cron(CronSchedule::parse(expr)?),
        (None, Some(raw)) => Schedule::Interval(parse_interval_seconds(raw)?),
        (None, None) => {
            if require_exec {
                return Err(anyhow!("one of --schedule or --interval is required"));
            }
            // status/uninstall don't need a real schedule; placeholder.
            Schedule::Interval(0)
        }
    };

    let exec_argv = if let Some(exec) = &p.exec {
        split_argv(exec)?
    } else if require_exec {
        return Err(anyhow!("--exec is required"));
    } else {
        Vec::new()
    };

    Ok(CronSpec {
        name,
        schedule,
        exec_argv,
        description: p.description.clone(),
        working_dir: p.working_dir.clone(),
        env: p.env.clone(),
        stdout_log: p.stdout_log.clone(),
        stderr_log: p.stderr_log.clone(),
        scope: p.scope,
    })
}

fn emit_ambient(kind: &str, spec: &CronSpec, backend: Backend) {
    // scanner-anchor: kind=chump_cron_installed (INFRA-2057)
    // scanner-anchor: kind=chump_cron_uninstalled (INFRA-2057)
    let schedule_str = match &spec.schedule {
        Schedule::Interval(s) => format!("interval:{s}s"),
        Schedule::Cron(_) => "cron".to_string(),
    };
    let exec_str = spec.exec_argv.join(" ");
    let _ = chump_ambient_cli::ambient_emit::emit(&chump_ambient_cli::ambient_emit::EmitArgs {
        kind: kind.to_string(),
        source: Some("chump-cron".to_string()),
        fields: vec![
            ("name".to_string(), spec.name.clone()),
            ("schedule".to_string(), schedule_str),
            ("exec".to_string(), exec_str),
            ("backend".to_string(), backend.as_str().to_string()),
            ("scope".to_string(), spec.scope.as_str().to_string()),
        ],
        ..Default::default()
    });
}

fn cmd_install(args: &[String]) -> Result<i32> {
    let parsed = parse_flags(args)?;
    let spec = build_spec(&parsed, true)?;
    let backend = Backend::detect();

    let outcome = ops::install(&spec, backend)?;
    emit_ambient("chump_cron_installed", &spec, backend);

    match outcome {
        ops::InstallOutcome::NoopUnchanged => {
            println!(
                "{}: already installed, config unchanged (no-op)",
                spec.label()
            );
        }
        ops::InstallOutcome::Installed => {
            println!("{}: installed via {}", spec.label(), backend.as_str());
        }
        ops::InstallOutcome::Reloaded => {
            println!(
                "{}: config changed, reloaded via {}",
                spec.label(),
                backend.as_str()
            );
        }
    }
    Ok(0)
}

fn cmd_uninstall(args: &[String]) -> Result<i32> {
    let parsed = parse_flags(args)?;
    let spec = build_spec(&parsed, false)?;
    let backend = Backend::detect();

    let removed = match backend {
        Backend::Launchd => ops::uninstall_launchd(&spec)?,
        Backend::Systemd => ops::uninstall_systemd(&spec)?,
    };

    if removed {
        emit_ambient("chump_cron_uninstalled", &spec, backend);
        println!("{}: uninstalled", spec.label());
    } else {
        println!("{}: not installed (no-op)", spec.label());
    }
    Ok(0)
}

fn cmd_status(args: &[String]) -> Result<i32> {
    let parsed = parse_flags(args)?;
    let spec = build_spec(&parsed, false)?;
    let backend = Backend::detect();
    println!("{}", ops::status(&spec, backend));
    Ok(0)
}

// `chump cron health` (INFRA-2046/META-110): audit every chump-managed
// plist/timer-unit for missing schedules (INFRA-1929 class), unloaded
// units, and stale last-run timestamps. Emits one ambient
// kind=chump_cron_managed event per managed entry (scanner-anchor:
// "kind":"chump_cron_managed") and exits non-zero if any entry carries a
// warning, so this composes as a CI/cron-daemon health gate.
fn cmd_health(args: &[String]) -> Result<i32> {
    let json = args.iter().any(|a| a == "--json");
    let entries = health::scan();

    for entry in &entries {
        let _ = chump_ambient_cli::ambient_emit::emit(&chump_ambient_cli::ambient_emit::EmitArgs {
            kind: entry.kind.to_string(),
            source: Some("chump-cron".to_string()),
            fields: vec![
                ("name".to_string(), entry.name.clone()),
                ("backend".to_string(), entry.backend.to_string()),
                ("installed".to_string(), entry.installed.to_string()),
                ("has_schedule".to_string(), entry.has_schedule.to_string()),
                ("loaded".to_string(), entry.loaded.to_string()),
                (
                    "warning_count".to_string(),
                    entry.warnings.len().to_string(),
                ),
            ],
            ..Default::default()
        });
    }

    if json {
        println!("{}", serde_json::to_string_pretty(&entries)?);
    } else if entries.is_empty() {
        println!("chump cron health: no chump-managed plists/units found");
    } else {
        for entry in &entries {
            let status = if entry.is_healthy() { "OK" } else { "WARN" };
            println!(
                "[{status}] {} ({}) installed={} schedule={} loaded={}",
                entry.name, entry.backend, entry.installed, entry.has_schedule, entry.loaded
            );
            for w in &entry.warnings {
                println!("    - {w}");
            }
        }
    }

    let unhealthy = entries.iter().filter(|e| !e.is_healthy()).count();
    Ok(if unhealthy > 0 { 1 } else { 0 })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_install_flags() {
        let args: Vec<String> = vec![
            "--name",
            "foo",
            "--schedule",
            "0 9 * * *",
            "--exec",
            "/bin/true",
            "--scope",
            "user",
        ]
        .into_iter()
        .map(String::from)
        .collect();
        let p = parse_flags(&args).unwrap();
        let spec = build_spec(&p, true).unwrap();
        assert_eq!(spec.name, "foo");
        assert_eq!(spec.exec_argv, vec!["/bin/true"]);
    }

    #[test]
    fn rejects_schedule_and_interval_together() {
        let args: Vec<String> = vec![
            "--name",
            "foo",
            "--schedule",
            "* * * * *",
            "--interval",
            "5s",
            "--exec",
            "x",
        ]
        .into_iter()
        .map(String::from)
        .collect();
        let p = parse_flags(&args).unwrap();
        assert!(build_spec(&p, true).is_err());
    }

    #[test]
    fn requires_name() {
        let p = parse_flags(&[]).unwrap();
        assert!(build_spec(&p, true).is_err());
    }

    #[test]
    fn help_exits_zero() {
        assert_eq!(run(&["--help".to_string()]), 0);
        assert_eq!(run(&[]), 0);
    }

    #[test]
    fn unknown_subcommand_exits_nonzero() {
        assert_eq!(run(&["bogus".to_string()]), 1);
    }
}
