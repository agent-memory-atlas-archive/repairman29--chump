//! Unit tests for chump-provision (INFRA-8194). Depth: happy-path for each
//! detector branch and each host variant's render, plus the edge/adversarial
//! cases the incidents taught us (a baked User=, %h at system scope, a
//! systemd unit handed to launchd, an unresolved placeholder). Gaps: nothing
//! here runs a real systemd or launchd; `systemd-analyze verify` on rendered
//! output is not exercised.

use super::*;
use std::path::PathBuf;

const PASSWD: &str = "\
root:x:0:0:root:/root:/bin/bash
ubuntu:x:1000:1000:Ubuntu:/home/ubuntu:/bin/bash
jeff:x:1001:1001::/home/jeff:/bin/bash
";

fn linux(euid: u32, user: &str, home: &str) -> Probe {
    Probe {
        os: "Linux".into(),
        has_systemctl: true,
        euid: Some(euid),
        user: Some(user.into()),
        home: Some(home.into()),
        passwd: Some(PASSWD.into()),
        ..Probe::default()
    }
}

fn repo_file(rel: &str) -> String {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(rel);
    std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("read {}: {e}", p.display()))
}

// ── detection ──────────────────────────────────────────────────────────────

#[test]
fn detect_termux_beats_linux() {
    let p = Probe {
        os: "Linux".into(),
        prefix: Some("/data/data/com.termux/files/usr".into()),
        has_systemctl: true,
        euid: Some(10234),
        ..Probe::default()
    };
    assert_eq!(detect(&p), Ok(Host::Termux));
}

#[test]
fn detect_darwin_is_launchd() {
    let p = Probe {
        os: "Darwin".into(),
        has_launchctl: true,
        euid: Some(501),
        ..Probe::default()
    };
    assert_eq!(detect(&p), Ok(Host::MacLaunchd));
}

#[test]
fn detect_systemd_root_is_system_scope() {
    assert_eq!(
        detect(&linux(0, "root", "/root")),
        Ok(Host::LinuxSystemdSystem)
    );
}

#[test]
fn detect_systemd_nonroot_is_user_scope() {
    assert_eq!(
        detect(&linux(1000, "ubuntu", "/home/ubuntu")),
        Ok(Host::LinuxSystemdUser)
    );
}

#[test]
fn detect_unknown_euid_falls_back_to_user_name() {
    let mut p = linux(0, "root", "/root");
    p.euid = None;
    assert_eq!(detect(&p), Ok(Host::LinuxSystemdSystem));
    p.user = Some("ubuntu".into());
    assert_eq!(detect(&p), Ok(Host::LinuxSystemdUser));
}

#[test]
fn detect_launchctl_without_darwin_uname() {
    let p = Probe {
        os: "Unknown".into(),
        has_launchctl: true,
        ..Probe::default()
    };
    assert_eq!(detect(&p), Ok(Host::MacLaunchd));
}

#[test]
fn detect_no_supervisor_is_an_error_not_a_guess() {
    let p = Probe {
        os: "Linux".into(),
        euid: Some(1000),
        ..Probe::default()
    };
    assert_eq!(
        detect(&p),
        Err(DetectError::NoSupervisor { os: "Linux".into() })
    );
}

#[test]
fn detect_override_wins_and_bad_override_errors() {
    let mut p = linux(1000, "ubuntu", "/home/ubuntu");
    p.host_override = Some("linux-systemd-system".into());
    assert_eq!(detect(&p), Ok(Host::LinuxSystemdSystem));
    p.host_override = Some("MacLaunchd".into());
    assert_eq!(detect(&p), Ok(Host::MacLaunchd));
    p.host_override = Some("freebsd-rc".into());
    assert!(matches!(detect(&p), Err(DetectError::BadOverride(_))));
    p.host_override = Some("  ".into());
    assert_eq!(detect(&p), Ok(Host::LinuxSystemdUser));
}

#[test]
fn host_names_round_trip_and_map_to_manifest_vocab() {
    for h in Host::ALL {
        assert_eq!(Host::parse(h.as_str()), Some(h));
    }
    assert_eq!(Host::MacLaunchd.platform(), "launchd");
    assert_eq!(Host::LinuxSystemdUser.platform(), "systemd");
    assert_eq!(Host::LinuxSystemdSystem.platform(), "systemd");
    assert_eq!(Host::Termux.platform(), "runit");
    assert_eq!(Host::LinuxSystemdSystem.run_scope(), RunScope::System);
    for h in [Host::MacLaunchd, Host::LinuxSystemdUser, Host::Termux] {
        assert_eq!(h.run_scope(), RunScope::User);
    }
}

// ── paths ──────────────────────────────────────────────────────────────────

#[test]
fn paths_user_scope_uses_invoking_user_and_xdg() {
    let mut p = linux(1000, "ubuntu", "/home/ubuntu");
    let hp = paths(Host::LinuxSystemdUser, &p).unwrap();
    assert_eq!(
        hp.unit_dir,
        PathBuf::from("/home/ubuntu/.config/systemd/user")
    );
    assert_eq!(hp.bin_dir, PathBuf::from("/home/ubuntu/.cargo/bin"));
    assert_eq!(hp.user, "ubuntu");
    p.xdg_config_home = Some("/srv/cfg".into());
    let hp = paths(Host::LinuxSystemdUser, &p).unwrap();
    assert_eq!(hp.unit_dir, PathBuf::from("/srv/cfg/systemd/user"));
}

#[test]
fn paths_system_scope_runs_as_run_user_not_root() {
    // The RESILIENT-1601 shape inverted: root installs, ubuntu runs.
    let mut p = linux(0, "root", "/root");
    p.run_user = Some("ubuntu".into());
    let hp = paths(Host::LinuxSystemdSystem, &p).unwrap();
    assert_eq!(hp.unit_dir, PathBuf::from("/etc/systemd/system"));
    assert_eq!(hp.user, "ubuntu");
    assert_eq!(hp.home, PathBuf::from("/home/ubuntu"));
    assert_eq!(hp.bin_dir, PathBuf::from("/home/ubuntu/.cargo/bin"));
}

#[test]
fn paths_system_scope_falls_back_to_repo_owner_then_root() {
    let mut p = linux(0, "root", "/root");
    p.repo_owner_uid = Some(1001);
    let hp = paths(Host::LinuxSystemdSystem, &p).unwrap();
    assert_eq!(
        (hp.user.as_str(), hp.home.clone()),
        ("jeff", PathBuf::from("/home/jeff"))
    );
    p.repo_owner_uid = None;
    let hp = paths(Host::LinuxSystemdSystem, &p).unwrap();
    assert_eq!(
        (hp.user.as_str(), hp.home.clone()),
        ("root", PathBuf::from("/root"))
    );
}

#[test]
fn paths_unknown_run_user_is_an_error_not_a_home_guess() {
    let mut p = linux(0, "root", "/root");
    p.run_user = Some("ghost".into());
    assert_eq!(
        paths(Host::LinuxSystemdSystem, &p),
        Err(DetectError::UnknownHome("ghost".into()))
    );
}

#[test]
fn paths_termux_and_mac() {
    let p = Probe {
        os: "Linux".into(),
        prefix: Some("/data/data/com.termux/files/usr".into()),
        user: Some("u0_a123".into()),
        home: Some("/data/data/com.termux/files/home".into()),
        ..Probe::default()
    };
    let hp = paths(Host::Termux, &p).unwrap();
    assert_eq!(
        hp.unit_dir,
        PathBuf::from("/data/data/com.termux/files/usr/var/service")
    );
    assert_eq!(
        hp.bin_dir,
        PathBuf::from("/data/data/com.termux/files/usr/bin")
    );

    let mut no_prefix = p.clone();
    no_prefix.prefix = None;
    assert_eq!(
        paths(Host::Termux, &no_prefix),
        Err(DetectError::MissingPrefix)
    );

    let m = Probe {
        os: "Darwin".into(),
        user: Some("pat".into()),
        home: Some("/Users/pat".into()),
        ..Probe::default()
    };
    let hp = paths(Host::MacLaunchd, &m).unwrap();
    assert_eq!(
        hp.unit_dir,
        PathBuf::from("/Users/pat/Library/LaunchAgents")
    );
    assert_eq!(hp.bin_dir, PathBuf::from("/Users/pat/.cargo/bin"));
}

// ── literal lint ───────────────────────────────────────────────────────────

#[test]
fn literal_rules_fire_on_each_host_literal() {
    let rules = |t: &str| -> Vec<&'static str> {
        find_host_literals(t).into_iter().map(|f| f.rule).collect()
    };
    assert_eq!(rules("User=jeff"), vec!["user-literal"]);
    assert_eq!(rules("  User=root"), vec!["user-literal"]);
    assert_eq!(
        rules("Environment=PATH=/home/jeff/.cargo/bin"),
        vec!["home-literal"]
    );
    assert_eq!(
        rules("source /root/.chump/providers.env"),
        vec!["root-literal"]
    );
    assert_eq!(
        rules("<string>/opt/homebrew/bin/chump</string>"),
        vec!["homebrew-literal"]
    );
}

#[test]
fn literal_rules_ignore_variables_and_placeholders() {
    for clean in [
        "User=$RUN_USER",
        "User=${run_user}",
        "User=<run-user>",
        "CHUMP_RUN_USER=ubuntu",
        "SUDO_User=x",
        "cd /home/$USER",
        "see /home/<name>",
        "chroot/foo",
        "HOME=/root",
        "Environment=HOME=__HOME__",
        "",
    ] {
        assert!(
            find_host_literals(clean).is_empty(),
            "false positive on {clean:?}"
        );
    }
}

#[test]
fn literal_rules_skip_comment_lines_but_not_shebangs() {
    // INFRA-8194 slice 2: a comment executes nothing (incident receipts live
    // there), so it is not a host assumption. A shebang pins the interpreter.
    for comment in [
        "# the old unit ran /root/Projects/chump as User=root",
        "    # PATH used to start with /opt/homebrew/bin",
        "#/home/jeff",
        "#",
    ] {
        assert!(
            find_host_literals(comment).is_empty(),
            "comment flagged: {comment:?}"
        );
    }
    let rules = |t: &str| -> Vec<&'static str> {
        find_host_literals(t).into_iter().map(|f| f.rule).collect()
    };
    assert_eq!(rules("#!/opt/homebrew/bin/bash"), vec!["homebrew-literal"]);
    // Quoted text in code is a live path, never skipped.
    assert_eq!(
        rules(r#"echo "installed /opt/homebrew/bin/chump""#),
        vec!["homebrew-literal"]
    );
    // A trailing comment on a code line does not hide the code.
    assert_eq!(rules("cd /root/chump # helsinki"), vec!["root-literal"]);
    // Line numbers still count the skipped comment lines.
    let f = find_host_literals("# /root/\nUser=jeff\n");
    assert_eq!(f.len(), 1);
    assert_eq!(f[0].line, 2);
    assert!(is_comment_line("  # x") && !is_comment_line("#!/bin/sh") && !is_comment_line("x # y"));
}

// ── brew prefix ────────────────────────────────────────────────────────────

#[test]
fn brew_prefix_is_apple_silicon_only_on_a_mac_that_has_it() {
    let mut mac = Probe {
        os: "Darwin".into(),
        user: Some("pat".into()),
        home: Some("/Users/pat".into()),
        has_opt_homebrew: true,
        ..Probe::default()
    };
    assert_eq!(
        brew_prefix(Host::MacLaunchd, &mac),
        PathBuf::from(APPLE_SILICON_BREW_PREFIX)
    );
    assert_eq!(
        paths(Host::MacLaunchd, &mac).unwrap().brew_prefix,
        PathBuf::from(APPLE_SILICON_BREW_PREFIX)
    );
    // Intel Mac: brew lives under /usr/local.
    mac.has_opt_homebrew = false;
    assert_eq!(
        brew_prefix(Host::MacLaunchd, &mac),
        PathBuf::from(DEFAULT_BREW_PREFIX)
    );
    // Linux never gets the Apple Silicon prefix, even if a stray dir exists.
    let mut lin = linux(1000, "ubuntu", "/home/ubuntu");
    lin.has_opt_homebrew = true;
    for host in [
        Host::LinuxSystemdUser,
        Host::LinuxSystemdSystem,
        Host::Termux,
    ] {
        assert_eq!(brew_prefix(host, &lin), PathBuf::from(DEFAULT_BREW_PREFIX));
    }
}

#[test]
fn render_resolves_brew_prefix() {
    let tpl = "<plist><string>/usr/local/bin:__BREW_PREFIX__/bin:__BREW_PREFIX__/sbin:/usr/bin:/bin</string></plist>\n";
    let mut ctx = RenderCtx {
        home: "/Users/pat".into(),
        repo_root: "/Users/pat/Projects/Chump".into(),
        bin_dir: "/Users/pat/.cargo/bin".into(),
        user: "pat".into(),
        brew_prefix: APPLE_SILICON_BREW_PREFIX.into(),
    };
    let out = render("x.plist", tpl, Host::MacLaunchd, &ctx).unwrap();
    assert_eq!(
        out,
        "<plist><string>/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin</string></plist>\n"
    );
    ctx.brew_prefix = DEFAULT_BREW_PREFIX.into();
    let out = render("x.plist", tpl, Host::MacLaunchd, &ctx).unwrap();
    assert!(
        out.contains("/usr/local/bin:/usr/local/bin:/usr/local/sbin"),
        "{out}"
    );
    assert!(PLACEHOLDERS.contains(&"__BREW_PREFIX__"));
}

// ── render ─────────────────────────────────────────────────────────────────

fn ubuntu_ctx() -> RenderCtx {
    RenderCtx {
        home: "/home/ubuntu".into(),
        repo_root: "/home/ubuntu/chump".into(),
        bin_dir: "/home/ubuntu/.cargo/bin".into(),
        user: "ubuntu".into(),
        brew_prefix: DEFAULT_BREW_PREFIX.into(),
    }
}

const MIGRATED: [&str; 4] = [
    "scripts/dispatch/chump-gap-close-decomposed.service",
    "scripts/dispatch/chump-gap-close-decomposed.timer",
    "scripts/dispatch/chump-organ-watchdog.service",
    "scripts/dispatch/chump-organ-watchdog.timer",
];

#[test]
fn migrated_templates_carry_no_host_literals() {
    for rel in MIGRATED {
        let found = find_host_literals(&repo_file(rel));
        assert!(found.is_empty(), "{rel} carries host literals: {found:?}");
    }
}

#[test]
fn migrated_templates_render_clean_for_every_systemd_variant() {
    let ctx = ubuntu_ctx();
    for rel in MIGRATED {
        let tpl = repo_file(rel);
        for host in [Host::LinuxSystemdUser, Host::LinuxSystemdSystem] {
            let out =
                render(rel, &tpl, host, &ctx).unwrap_or_else(|e| panic!("{rel} on {host}: {e}"));
            for bad in [
                "/root/",
                "jeff",
                "/opt/homebrew",
                "__HOME__",
                "__REPO_ROOT__",
                "__BIN_DIR__",
                "__NODE_ENV__",
            ] {
                assert!(
                    !out.contains(bad),
                    "{rel} rendered for {host} still contains {bad:?}:\n{out}"
                );
            }
            let active_pct_h = out
                .lines()
                .any(|l| !l.trim_start().starts_with('#') && l.contains("%h"));
            assert!(
                !active_pct_h,
                "{rel} rendered for {host} has %h in an active directive"
            );
            let user_lines: Vec<&str> = out.lines().filter(|l| l.starts_with("User=")).collect();
            let is_service = rel.ends_with(".service");
            match (host, is_service) {
                (Host::LinuxSystemdSystem, true) => {
                    assert_eq!(user_lines, vec!["User=ubuntu"], "{rel}")
                }
                _ => assert!(
                    user_lines.is_empty(),
                    "{rel} on {host} must carry no User= (217/USER): {user_lines:?}"
                ),
            }
            if is_service {
                assert!(
                    out.contains("Environment=HOME=/home/ubuntu"),
                    "{rel} on {host}:\n{out}"
                );
                assert!(
                    out.contains("/home/ubuntu/chump"),
                    "{rel} on {host} lost the repo root:\n{out}"
                );
            }
        }
    }
}

/// Every tracked systemd unit that is NOT on the shrink-only host-literal
/// allowlist is, by construction, a template: it must render cleanly through
/// the enum for both systemd scopes. This is what keeps a migrated unit from
/// quietly regressing (and what makes deleting an allowlist line safe).
#[test]
fn every_non_allowlisted_dispatch_unit_renders_for_both_systemd_scopes() {
    let allow = repo_file("scripts/ci/provision-host-literal-allowlist.txt");
    // Entries may carry a trailing `# reason` (the named-host (c) set).
    let allowed: std::collections::HashSet<&str> = allow
        .lines()
        .map(|l| l.split('#').next().unwrap_or("").trim())
        .filter(|l| !l.is_empty())
        .collect();
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../scripts/dispatch");
    let mut rendered = 0;
    for entry in std::fs::read_dir(&dir).unwrap() {
        let path = entry.unwrap().path();
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        if !(name.ends_with(".service") || name.ends_with(".timer")) {
            continue;
        }
        let rel = format!("scripts/dispatch/{name}");
        if allowed.contains(rel.as_str()) {
            continue;
        }
        let tpl = std::fs::read_to_string(&path).unwrap();
        for host in [Host::LinuxSystemdUser, Host::LinuxSystemdSystem] {
            render(&rel, &tpl, host, &ubuntu_ctx())
                .unwrap_or_else(|e| panic!("{rel} does not render for {host}: {e}"));
        }
        rendered += 1;
    }
    assert!(
        rendered >= 40,
        "only {rendered} dispatch units rendered; expected the migrated set"
    );
}

/// The launchd twin of the dispatch sweep (INFRA-8194 slice 2): every tracked
/// plist under launchd/, scripts/plists/ and scripts/setup/ that is NOT on the
/// allowlist must render on a Mac, leaving no placeholder and no host literal.
#[test]
fn every_non_allowlisted_plist_renders_on_mac() {
    let allow = repo_file("scripts/ci/provision-host-literal-allowlist.txt");
    let allowed: std::collections::HashSet<&str> = allow
        .lines()
        .map(|l| l.split('#').next().unwrap_or("").trim())
        .filter(|l| !l.is_empty())
        .collect();
    let ctx = RenderCtx {
        home: "/Users/pat".into(),
        repo_root: "/Users/pat/Projects/Chump".into(),
        bin_dir: "/Users/pat/.cargo/bin".into(),
        user: "pat".into(),
        brew_prefix: APPLE_SILICON_BREW_PREFIX.into(),
    };
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let mut rendered = 0;
    for dir in [
        "launchd",
        "scripts/plists",
        "scripts/setup",
        "scripts/setup/launchd",
    ] {
        let Ok(rd) = std::fs::read_dir(root.join(dir)) else {
            continue;
        };
        for entry in rd {
            let path = entry.unwrap().path();
            let name = path.file_name().unwrap().to_string_lossy().to_string();
            if !name.contains(".plist") {
                continue;
            }
            let rel = format!("{dir}/{name}");
            if allowed.contains(rel.as_str()) {
                continue;
            }
            let tpl = std::fs::read_to_string(&path).unwrap();
            let out = render(&rel, &tpl, Host::MacLaunchd, &ctx)
                .unwrap_or_else(|e| panic!("{rel} does not render on mac: {e}"));
            assert!(
                find_host_literals(&out)
                    .iter()
                    .all(|f| f.rule == "homebrew-literal"),
                "{rel} rendered with a non-brew host literal"
            );
            rendered += 1;
        }
    }
    assert!(
        rendered >= 60,
        "only {rendered} plists rendered; expected the migrated launchd set"
    );
}

/// INFRA-8571 (Phase R R5 slice 3): manifest-driven render sweep. Every
/// `enabled` organ in scripts/ops/organ-manifest.txt that ships a tracked
/// systemd template under scripts/dispatch/ must render through the typed Host
/// enum with the RIGHT outcome on all three host variants — the manifest, the
/// templates, and the renderer agreeing with no baked host literal anywhere.
/// linux-systemd-user: renders Ok, and a .service carries NO User= line (a user
/// manager cannot switch identity: 216/GROUP, 217/USER). linux-systemd-system:
/// renders Ok, and a .service carries exactly one User= line — `root` for a
/// keep-root organ (organ-deploy), else the repo-owning run user. mac-launchd:
/// HostMismatch, so a systemd unit never silently renders into a launchd agent.
///
/// Complements every_non_allowlisted_dispatch_unit_renders_* (which sweeps the
/// dispatch directory) by keying off the MANIFEST roster and asserting the
/// per-scope User= outcome, including the keep-root branch via a keep-root
/// organ's sibling .service.
#[test]
fn manifest_units_render_right_on_every_host() {
    let manifest = repo_file("scripts/ops/organ-manifest.txt");
    let dispatch = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../scripts/dispatch");
    let ctx = ubuntu_ctx();

    // The per-host render contract for one tracked systemd template.
    let check = |rel: &str, tpl: &str| {
        assert!(
            find_host_literals(tpl).is_empty(),
            "{rel} (manifest-enabled) carries a host literal"
        );
        let is_service = rel.ends_with(".service");

        let u = render(rel, tpl, Host::LinuxSystemdUser, &ctx)
            .unwrap_or_else(|e| panic!("{rel} must render for linux-systemd-user: {e}"));
        assert!(
            !u.lines().any(|l| l.starts_with("User=")),
            "{rel} on linux-systemd-user must carry no User= line:\n{u}"
        );

        let s = render(rel, tpl, Host::LinuxSystemdSystem, &ctx)
            .unwrap_or_else(|e| panic!("{rel} must render for linux-systemd-system: {e}"));
        let users: Vec<&str> = s.lines().filter(|l| l.starts_with("User=")).collect();
        if is_service {
            let want = if is_keep_root_unit(rel) {
                "User=root"
            } else {
                "User=ubuntu"
            };
            assert_eq!(users, vec![want], "{rel} on linux-systemd-system");
        } else {
            assert!(
                users.is_empty(),
                "{rel} (.timer) has no [Service]/User=: {users:?}"
            );
        }
        for leftover in [
            "__HOME__",
            "__REPO_ROOT__",
            "__BIN_DIR__",
            "__NODE_ENV__",
            "__BREW_PREFIX__",
            "/root/",
            "/opt/homebrew",
        ] {
            assert!(
                !s.contains(leftover),
                "{rel} rendered output still contains {leftover:?}:\n{s}"
            );
        }

        assert!(
            matches!(
                render(rel, tpl, Host::MacLaunchd, &ctx),
                Err(RenderError::HostMismatch {
                    kind: UnitKind::Systemd,
                    ..
                })
            ),
            "{rel} (a systemd unit) must refuse to render on mac-launchd"
        );
    };

    let mut swept = 0;
    let mut keep_root_services = 0;
    for line in manifest.lines() {
        let t = line.trim_start();
        if t.is_empty() || t.starts_with('#') {
            continue;
        }
        let mut toks = t.split_whitespace();
        if toks.next() != Some("enabled") {
            continue;
        }
        let Some(unit) = toks.next() else { continue };
        if !(unit.ends_with(".service") || unit.ends_with(".timer")) {
            continue;
        }
        // Untracked organs (CJ-legacy, postgrest, pure-launchd Linux-port-TODO,
        // and the housekeeping loop-services generated by
        // install-node-housekeeping.sh) have no tracked systemd template to
        // render — not this sweep's subject.
        let Ok(tpl) = std::fs::read_to_string(dispatch.join(unit)) else {
            continue;
        };
        let rel = format!("scripts/dispatch/{unit}");
        check(&rel, &tpl);
        swept += 1;

        // Exercise the keep-root User=root branch via the sibling .service of a
        // keep-root timer (organ-deploy.timer is the manifest's keep-root line;
        // its .service is what actually carries User=root at system scope).
        if unit.ends_with(".timer") && is_keep_root_unit(unit) {
            let svc = unit.replace(".timer", ".service");
            if let Ok(svc_tpl) = std::fs::read_to_string(dispatch.join(&svc)) {
                let srel = format!("scripts/dispatch/{svc}");
                check(&srel, &svc_tpl);
                keep_root_services += 1;
            }
        }
    }
    assert!(
        swept >= 30,
        "manifest sweep covered only {swept} tracked systemd units; expected the migrated roster"
    );
    assert!(
        keep_root_services >= 1,
        "expected a keep-root organ (organ-deploy) exercised for User=root at system scope"
    );
}

#[test]
fn systemd_templates_refuse_non_systemd_hosts() {
    let tpl = repo_file(MIGRATED[0]);
    for host in [Host::MacLaunchd, Host::Termux] {
        assert!(matches!(
            render(MIGRATED[0], &tpl, host, &ubuntu_ctx()),
            Err(RenderError::HostMismatch {
                kind: UnitKind::Systemd,
                ..
            })
        ));
    }
}

#[test]
fn render_refuses_a_template_with_a_baked_user() {
    // The literal RESILIENT-1601 unit shape.
    let tpl = "[Service]\nUser=jeff\nEnvironment=HOME=/home/jeff\nExecStart=/bin/true\n";
    match render("x.service", tpl, Host::LinuxSystemdUser, &ubuntu_ctx()) {
        Err(RenderError::HostLiterals(f)) => {
            let rules: Vec<_> = f.iter().map(|x| x.rule).collect();
            assert_eq!(rules, vec!["user-literal", "home-literal"]);
        }
        other => panic!("expected HostLiterals, got {other:?}"),
    }
}

#[test]
fn render_refuses_percent_h_at_system_scope_only() {
    // INFRA-3647: %h at system scope is /root regardless of User=.
    let tpl = "[Service]\n# %h is fine in a comment\nExecStart=%h/bin/x\n";
    assert_eq!(
        render("x.service", tpl, Host::LinuxSystemdSystem, &ubuntu_ctx()),
        Err(RenderError::SystemScopeHomeSpecifier { line: 3 })
    );
    let out = render("x.service", tpl, Host::LinuxSystemdUser, &ubuntu_ctx()).unwrap();
    assert!(out.contains("ExecStart=%h/bin/x"));
}

#[test]
fn render_reports_unresolved_placeholders() {
    let tpl = "[Service]\nExecStart=__REPO_ROOT__/x --who __OPERATOR__\n";
    assert_eq!(
        render("x.service", tpl, Host::LinuxSystemdUser, &ubuntu_ctx()),
        Err(RenderError::UnresolvedPlaceholder(vec![
            "__OPERATOR__".into()
        ]))
    );
}

#[test]
fn render_launchd_plist_on_mac_only() {
    let tpl = "<plist><dict><key>ProgramArguments</key><array><string>__BIN_DIR__/chump</string>\
               <string>__REPO_ROOT__</string></array></dict></plist>\n";
    let ctx = RenderCtx {
        home: "/Users/pat".into(),
        repo_root: "/Users/pat/Projects/chump".into(),
        bin_dir: "/Users/pat/.cargo/bin".into(),
        user: "pat".into(),
        brew_prefix: APPLE_SILICON_BREW_PREFIX.into(),
    };
    let out = render("com.chump.x.plist.tmpl", tpl, Host::MacLaunchd, &ctx).unwrap();
    assert!(out.contains("<string>/Users/pat/.cargo/bin/chump</string>"));
    assert!(!out.contains("User="));
    assert!(matches!(
        render("com.chump.x.plist", tpl, Host::LinuxSystemdUser, &ctx),
        Err(RenderError::HostMismatch {
            kind: UnitKind::Launchd,
            ..
        })
    ));
    for name in ["x.plist.example", "x.plist.template", "x.plist.tmpl"] {
        assert_eq!(UnitKind::from_name(name), Some(UnitKind::Launchd), "{name}");
    }
    assert!(matches!(
        render("README.md", tpl, Host::MacLaunchd, &ctx),
        Err(RenderError::UnknownKind(_))
    ));
}

#[test]
fn keep_root_units_render_user_root_at_system_scope_only() {
    let rel = "scripts/dispatch/chump-organ-deploy.service";
    let tpl = repo_file(rel);
    assert!(
        !tpl.lines().any(|l| l.starts_with("User=")),
        "{rel} must not bake User= (the renderer owns it)"
    );
    assert!(is_keep_root_unit(rel) && !is_keep_root_unit("chump-organ-watchdog.service"));
    let sys = render(rel, &tpl, Host::LinuxSystemdSystem, &ubuntu_ctx()).unwrap();
    let users: Vec<&str> = sys.lines().filter(|l| l.starts_with("User=")).collect();
    assert_eq!(users, vec!["User=root"], "{sys}");
    // Paths still resolve to the run user's home, not root's.
    assert!(sys.contains("Environment=HOME=/home/ubuntu"), "{sys}");
    assert!(sys.contains("CHUMP_REPO_ROOT=/home/ubuntu/chump"), "{sys}");
    let user = render(rel, &tpl, Host::LinuxSystemdUser, &ubuntu_ctx()).unwrap();
    assert!(!user.lines().any(|l| l.starts_with("User=")), "{user}");
}

#[test]
fn render_preserves_trailing_newline_when_injecting_user() {
    let out = render(
        "x.service",
        "[Unit]\n[Service]\nExecStart=/bin/true\n",
        Host::LinuxSystemdSystem,
        &ubuntu_ctx(),
    )
    .unwrap();
    assert_eq!(out, "[Unit]\n[Service]\nUser=ubuntu\nExecStart=/bin/true\n");
}

// ── CLI ────────────────────────────────────────────────────────────────────

#[test]
fn cli_host_and_render_exit_codes() {
    let p = linux(1000, "ubuntu", "/home/ubuntu");
    assert_eq!(cli::run_host(&[], &p), 0);
    assert_eq!(cli::run_host(&["--json".into()], &p), 0);
    assert_eq!(
        cli::run_host(&["--field".into(), "run-scope".into()], &p),
        0
    );
    assert_eq!(cli::run_host(&["--field".into(), "nope".into()], &p), 2);
    assert_eq!(cli::run_host(&["--bogus".into()], &p), 2);
    let none = Probe {
        os: "Linux".into(),
        ..Probe::default()
    };
    assert_eq!(cli::run_host(&[], &none), 1);

    let dir = std::env::temp_dir().join(format!("chump-provision-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let out = dir.join("out.service");
    let src = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(MIGRATED[0]);
    let args: Vec<String> = vec![
        src.to_string_lossy().into(),
        "--host".into(),
        "linux-systemd-system".into(),
        "--repo-root".into(),
        "/home/ubuntu/chump".into(),
        "--out".into(),
        out.to_string_lossy().into(),
    ];
    let mut root = linux(0, "root", "/root");
    root.run_user = Some("ubuntu".into());
    assert_eq!(cli::run_render(&args, &root), 0);
    let rendered = std::fs::read_to_string(&out).unwrap();
    assert!(rendered.contains("User=ubuntu"), "{rendered}");
    assert!(
        rendered.contains("WorkingDirectory=/home/ubuntu/chump"),
        "{rendered}"
    );

    let bad = dir.join("bad.service");
    std::fs::write(&bad, "[Service]\nUser=jeff\n").unwrap();
    assert_eq!(cli::run_render(&[bad.to_string_lossy().into()], &p), 1);
    assert_eq!(cli::run_render(&[], &p), 2);
    let _ = std::fs::remove_dir_all(&dir);
}
