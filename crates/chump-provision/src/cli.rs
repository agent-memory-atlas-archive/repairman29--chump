//! `chump node host` and `chump node render-unit` (INFRA-8194).
//!
//! Kept in the crate so `src/main.rs` carries only a thin dispatch arm.

use crate::{detect, paths, render, Host, HostPaths, Probe, RenderCtx};
use std::path::PathBuf;

const USAGE: &str = "\
Usage:
  chump node host [--json] [--field host|platform|run-scope|unit-dir|bin-dir|home|user|brew-prefix]
      Print the detected host variant and the paths it implies.
  chump node render-unit <template> [--host <variant>] [--repo-root <dir>]
                                    [--user <name>] [--home <dir>] [--out <file>]
      Render a placeholder unit/plist template for this (or the named) host.
      Placeholders: __HOME__ __REPO_ROOT__ __BIN_DIR__ __NODE_ENV__ __BREW_PREFIX__.
      A template carrying User=<name>, /home/<name>, /root/ or /opt/homebrew
      is refused; User= is injected only for linux-systemd-system.
  chump node scopes [--json] [--install-guard]
      Enumerate chump work organs in BOTH systemd scopes (--user + system) or
      the mac launchd user domain. Exits 3 on a two-scope node. --install-guard
      refuses (exit 3, kind=node_second_scope_refused) if the OTHER scope
      already has an install.
  chump node ensure-nextest [--dry-run] [--json]
      Idempotently ensure cargo-nextest is installed on linux-systemd and
      mac-launchd hosts (INFRA-8572).

Host variants: mac-launchd, linux-systemd-user, linux-systemd-system, termux
Override detection with CHUMP_PROVISION_HOST=<variant>.";

/// Entry point for `chump node <args...>` (args exclude `chump node`).
/// Returns the process exit code.
pub fn run_cli(args: &[String]) -> i32 {
    match args.first().map(String::as_str) {
        Some("host") => run_host(&args[1..], &Probe::from_env()),
        Some("render-unit") => run_render(&args[1..], &Probe::from_env()),
        // RESILIENT-1615: two-scope enumeration + installer second-scope guard.
        Some("scopes") => crate::scopes_live::run_scopes(&args[1..], &Probe::from_env()),
        // INFRA-8572: idempotent cargo-nextest provisioning on linux-systemd / mac-launchd.
        Some("ensure-nextest") => run_ensure_nextest(&args[1..], &Probe::from_env()),
        Some("-h") | Some("--help") | Some("help") => {
            println!("{USAGE}");
            0
        }
        _ => {
            eprintln!("{USAGE}");
            2
        }
    }
}

fn host_json(p: &HostPaths) -> serde_json::Value {
    serde_json::json!({
        "host": p.host.as_str(),
        "platform": p.host.platform(),
        "run_scope": p.host.run_scope().as_str(),
        "unit_dir": p.unit_dir.to_string_lossy(),
        "bin_dir": p.bin_dir.to_string_lossy(),
        "home": p.home.to_string_lossy(),
        "user": p.user,
        "brew_prefix": p.brew_prefix.to_string_lossy(),
    })
}

fn field(p: &HostPaths, name: &str) -> Option<String> {
    Some(match name {
        "host" => p.host.as_str().to_string(),
        "platform" => p.host.platform().to_string(),
        "run-scope" | "run_scope" => p.host.run_scope().as_str().to_string(),
        "unit-dir" | "unit_dir" => p.unit_dir.to_string_lossy().into_owned(),
        "bin-dir" | "bin_dir" => p.bin_dir.to_string_lossy().into_owned(),
        "home" => p.home.to_string_lossy().into_owned(),
        "user" => p.user.clone(),
        "brew-prefix" | "brew_prefix" => p.brew_prefix.to_string_lossy().into_owned(),
        _ => return None,
    })
}

/// `chump node host`. Probe is injected so tests can fake the host.
pub fn run_host(args: &[String], probe: &Probe) -> i32 {
    let mut json = false;
    let mut want: Option<String> = None;
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--json" => json = true,
            "--field" => match it.next() {
                Some(f) => want = Some(f.clone()),
                None => {
                    eprintln!("chump node host: --field needs a value\n{USAGE}");
                    return 2;
                }
            },
            "-h" | "--help" => {
                println!("{USAGE}");
                return 0;
            }
            other => {
                eprintln!("chump node host: unknown argument {other:?}\n{USAGE}");
                return 2;
            }
        }
    }
    let host = match detect(probe) {
        Ok(h) => h,
        Err(e) => {
            eprintln!("chump node host: {e}");
            return 1;
        }
    };
    let p = match paths(host, probe) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("chump node host: detected {host}, but {e}");
            return 1;
        }
    };
    if let Some(f) = want {
        return match field(&p, &f) {
            Some(v) => {
                println!("{v}");
                0
            }
            None => {
                eprintln!("chump node host: unknown field {f:?}\n{USAGE}");
                2
            }
        };
    }
    if json {
        println!("{}", host_json(&p));
    } else {
        println!("host:       {}", p.host);
        println!("platform:   {}", p.host.platform());
        println!("run-scope:  {}", p.host.run_scope().as_str());
        println!("unit-dir:   {}", p.unit_dir.display());
        println!("bin-dir:    {}", p.bin_dir.display());
        println!("home:       {}", p.home.display());
        println!("user:       {}", p.user);
        println!("brew-prefix: {}", p.brew_prefix.display());
    }
    0
}

/// `chump node render-unit`. Probe is injected so tests can fake the host.
pub fn run_render(args: &[String], probe: &Probe) -> i32 {
    let mut template: Option<PathBuf> = None;
    let mut host_arg: Option<String> = None;
    let mut repo_root: Option<PathBuf> = None;
    let mut user: Option<String> = None;
    let mut home: Option<PathBuf> = None;
    let mut out: Option<PathBuf> = None;
    let mut it = args.iter();
    while let Some(a) = it.next() {
        let mut val = |flag: &str| -> Option<String> {
            let v = it.next().cloned();
            if v.is_none() {
                eprintln!("chump node render-unit: {flag} needs a value");
            }
            v
        };
        match a.as_str() {
            "--host" => match val("--host") {
                Some(v) => host_arg = Some(v),
                None => return 2,
            },
            "--repo-root" => match val("--repo-root") {
                Some(v) => repo_root = Some(v.into()),
                None => return 2,
            },
            "--user" => match val("--user") {
                Some(v) => user = Some(v),
                None => return 2,
            },
            "--home" => match val("--home") {
                Some(v) => home = Some(v.into()),
                None => return 2,
            },
            "--out" => match val("--out") {
                Some(v) => out = Some(v.into()),
                None => return 2,
            },
            "-h" | "--help" => {
                println!("{USAGE}");
                return 0;
            }
            s if s.starts_with("--") => {
                eprintln!("chump node render-unit: unknown flag {s:?}\n{USAGE}");
                return 2;
            }
            s => {
                if template.is_some() {
                    eprintln!("chump node render-unit: only one template per call");
                    return 2;
                }
                template = Some(s.into());
            }
        }
    }
    let Some(template) = template else {
        eprintln!("chump node render-unit: missing <template>\n{USAGE}");
        return 2;
    };

    let host = match host_arg {
        Some(h) => match Host::parse(&h) {
            Some(h) => h,
            None => {
                eprintln!("chump node render-unit: unknown host {h:?}");
                return 2;
            }
        },
        None => match detect(probe) {
            Ok(h) => h,
            Err(e) => {
                eprintln!("chump node render-unit: {e}");
                return 1;
            }
        },
    };

    // --user/--home pin the run identity explicitly (an installer that already
    // resolved CHUMP_RUN_USER); otherwise derive it from the probe.
    let mut probe = probe.clone();
    if let Some(u) = &user {
        probe.run_user = Some(u.clone());
    }
    let mut hp = match (paths(host, &probe), &user, &home) {
        (Ok(p), _, _) => p,
        (Err(_), Some(u), Some(h)) => HostPaths {
            host,
            unit_dir: PathBuf::new(),
            bin_dir: h.join(".cargo/bin"),
            home: h.clone(),
            user: u.clone(),
            brew_prefix: crate::brew_prefix(host, &probe),
        },
        (Err(e), _, _) => {
            eprintln!("chump node render-unit: {e}");
            return 1;
        }
    };
    if let Some(u) = user {
        if u != hp.user && home.is_none() {
            eprintln!(
                "chump node render-unit: --user {u} differs from the resolved user {}; pass --home too",
                hp.user
            );
            return 2;
        }
        hp.user = u;
    }
    if let Some(h) = home {
        if host != Host::Termux {
            hp.bin_dir = h.join(".cargo/bin");
        }
        hp.home = h;
    }
    let repo = repo_root
        .or_else(|| {
            std::env::var("CHUMP_REPO_ROOT")
                .ok()
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
        })
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_else(|| PathBuf::from("."));
    let ctx = RenderCtx::from_paths(&hp, repo);

    let text = match std::fs::read_to_string(&template) {
        Ok(t) => t,
        Err(e) => {
            eprintln!(
                "chump node render-unit: cannot read {}: {e}",
                template.display()
            );
            return 1;
        }
    };
    let name = template.to_string_lossy();
    let rendered = match render(&name, &text, host, &ctx) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("chump node render-unit: {}: {e}", template.display());
            return 1;
        }
    };
    match out {
        Some(o) => {
            if let Err(e) = std::fs::write(&o, rendered) {
                eprintln!("chump node render-unit: cannot write {}: {e}", o.display());
                return 1;
            }
        }
        None => print!("{rendered}"),
    }
    0
}

/// `chump node ensure-nextest` (INFRA-8572).
pub fn run_ensure_nextest(args: &[String], probe: &Probe) -> i32 {
    let mut dry_run = false;
    let mut json = false;
    for a in args {
        match a.as_str() {
            "--dry-run" => dry_run = true,
            "--json" => json = true,
            "-h" | "--help" => {
                println!("{USAGE}");
                return 0;
            }
            other => {
                eprintln!("chump node ensure-nextest: unknown argument {other:?}\n{USAGE}");
                return 2;
            }
        }
    }
    let host = match detect(probe) {
        Ok(h) => h,
        Err(e) => {
            eprintln!("chump node ensure-nextest: {e}");
            return 1;
        }
    };
    let hp = match paths(host, probe) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("chump node ensure-nextest: detected {host}, but {e}");
            return 1;
        }
    };
    let on_path_bin = std::env::var_os("PATH").and_then(|p| {
        std::env::split_paths(&p)
            .map(|d| d.join("cargo-nextest"))
            .find(|c| c.is_file())
    });
    let arch = std::env::consts::ARCH;
    let plan = crate::plan_cargo_nextest(host, &hp, arch, on_path_bin);
    match &plan {
        crate::NextestProvisionPlan::NotApplicable { host } => {
            if json {
                println!(
                    "{}",
                    serde_json::json!({"status": "not_applicable", "host": host.as_str()})
                );
            } else {
                println!("cargo-nextest: not applicable on {host}");
            }
            0
        }
        crate::NextestProvisionPlan::AlreadyInstalled { bin } => {
            if json {
                println!(
                    "{}",
                    serde_json::json!({"status": "already_installed", "bin": bin.to_string_lossy()})
                );
            } else {
                println!("cargo-nextest: already installed at {}", bin.display());
            }
            0
        }
        crate::NextestProvisionPlan::Install {
            bin,
            archive_url,
            cargo_fallback,
        } => {
            if dry_run {
                if json {
                    println!(
                        "{}",
                        serde_json::json!({
                            "status": "would_install",
                            "bin": bin.to_string_lossy(),
                            "archive_url": archive_url,
                            "cargo_fallback": cargo_fallback,
                        })
                    );
                } else {
                    println!(
                        "cargo-nextest: would install to {} (archive={:?}, fallback={})",
                        bin.display(),
                        archive_url,
                        cargo_fallback.join(" ")
                    );
                }
                return 0;
            }
            if let Some(parent) = bin.parent() {
                if let Err(e) = std::fs::create_dir_all(parent) {
                    eprintln!(
                        "chump node ensure-nextest: cannot create {}: {e}",
                        parent.display()
                    );
                    return 1;
                }
                if let Some(url) = archive_url {
                    let cmd = format!(
                        "curl -fsSL '{url}' | tar -xzf - -C '{}' cargo-nextest",
                        parent.display()
                    );
                    if std::process::Command::new("sh")
                        .args(["-c", &cmd])
                        .status()
                        .is_ok_and(|s| s.success())
                        && bin.is_file()
                    {
                        println!(
                            "cargo-nextest: installed prebuilt binary to {}",
                            bin.display()
                        );
                        return 0;
                    }
                }
            }
            if std::process::Command::new(cargo_fallback[0])
                .args(&cargo_fallback[1..])
                .status()
                .is_ok_and(|s| s.success())
            {
                println!("cargo-nextest: installed via {}", cargo_fallback.join(" "));
                0
            } else {
                eprintln!("chump node ensure-nextest: failed to install cargo-nextest");
                1
            }
        }
    }
}
