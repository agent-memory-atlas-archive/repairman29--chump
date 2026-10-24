//! chump-provision: typed host provisioning for ChumpOS nodes.
//!
//! INFRA-8194 (Phase R, R5). Every host-assumption incident on the fleet has
//! been the same bug wearing a different hat: a shipped unit or script baked in
//! ONE machine's identity, and a different machine ran it.
//!
//! * `chump-gap-close-decomposed.service` shipped `User=jeff` and was installed
//!   into a systemd `--user` manager on cuphead, where the user is `ubuntu`:
//!   exit `217/USER` every ten minutes (RESILIENT-1601).
//! * `chump-organ-watchdog.service` used `%h`, which a SYSTEM-scope unit always
//!   resolves to the manager's home (`/root`) no matter what `User=` says, so
//!   CJ ran `/root/Projects/chump/...` as `jeff` and got status 126
//!   (INFRA-3647).
//! * a root-owned stale `/usr/local/bin/chump` (RESILIENT-1602), an abandoned
//!   `/root/.chumpnode` second install with about 15 units (INFRA-8049), a
//!   brew-only bootstrap on Linux (INFRA-8112), and launchd assumptions on a
//!   Linux node (INFRA-8114).
//!
//! This crate makes the host a TYPE instead of a pile of `uname` checks spread
//! through shell scripts:
//!
//! * [`Host`] is the closed set of supervisors a node can have.
//! * [`detect`] maps a [`Probe`] (uname, `launchctl`/`systemctl` presence,
//!   `$PREFIX`, euid, passwd) to exactly one [`Host`]. The probe is plain data,
//!   so every branch is unit-tested on faked inputs.
//! * [`paths`] derives what that host implies (unit dir, bin dir, home, user).
//! * [`render`] turns a placeholder template (`__HOME__`, `__REPO_ROOT__`,
//!   `__BIN_DIR__`, `__NODE_ENV__`, `__BREW_PREFIX__`) into a concrete unit for
//!   one host. It
//!   REFUSES a template that carries a host literal (`User=<name>`,
//!   `/home/<name>`, `/root/`, `/opt/homebrew`), refuses a unit kind the host
//!   cannot run (a systemd unit on launchd), refuses `%h` in a system-scope
//!   systemd unit, and is the only place `User=` is ever written: injected for
//!   [`Host::LinuxSystemdSystem`], never for a user manager.
//!
//! The shell mirror of the placeholder step lives in
//! `scripts/ops/lib/organ-unit-install-lib.sh` (`organ_unit_host_rewrite`), so
//! an installer that runs before the `chump` binary exists renders the same
//! tokens. `scripts/ci/test-provision-no-host-literals.sh` uses the same four
//! literal rules as [`find_host_literals`].

pub mod cli;
pub mod node_env; // INFRA-8588: node.env format invariant (bare KEY=VALUE, no export)
pub mod scopes; // RESILIENT-1615: two-scope node enumeration (pure logic)
pub mod scopes_live; // RESILIENT-1615: live systemctl/launchctl runner + `node scopes` CLI

use std::fmt;
use std::path::{Path, PathBuf};

/// The closed set of supervisors a ChumpOS node can run its organs under.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Host {
    /// macOS, organs are launchd LaunchAgents in the user's domain.
    MacLaunchd,
    /// Linux with systemd, installing into the invoking user's `--user` manager
    /// (`~/.config/systemd/user`). A user manager cannot switch identity, so a
    /// unit placed here must carry no `User=`/`Group=` (RESILIENT-1571, 1601).
    LinuxSystemdUser,
    /// Linux with systemd, installing as root into `/etc/systemd/system`. Units
    /// run as the repo-owning run user, injected as `User=` by the renderer.
    LinuxSystemdSystem,
    /// Android Termux, organs are runit services under `$PREFIX/var/service`.
    Termux,
}

/// Which manager scope a host installs into.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RunScope {
    User,
    System,
}

impl RunScope {
    pub fn as_str(self) -> &'static str {
        match self {
            RunScope::User => "user",
            RunScope::System => "system",
        }
    }
}

/// The kind of supervisor artifact a template renders into.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum UnitKind {
    Systemd,
    Launchd,
    Runit,
}

impl UnitKind {
    /// Classify a template by file name. A trailing `.tmpl` / `.template` /
    /// `.example` is ignored so `foo.service.tmpl` is a systemd unit and
    /// `foo.plist.example` a launchd plist.
    pub fn from_name(name: &str) -> Option<UnitKind> {
        let base = Path::new(name)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or(name);
        let base = base
            .strip_suffix(".tmpl")
            .or_else(|| base.strip_suffix(".template"))
            .or_else(|| base.strip_suffix(".example"))
            .unwrap_or(base);
        const SYSTEMD: [&str; 6] = [".service", ".timer", ".socket", ".path", ".target", ".conf"];
        if SYSTEMD.iter().any(|ext| base.ends_with(ext)) {
            Some(UnitKind::Systemd)
        } else if base.ends_with(".plist") {
            Some(UnitKind::Launchd)
        } else if base == "run" || base.ends_with(".runit") {
            Some(UnitKind::Runit)
        } else {
            None
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            UnitKind::Systemd => "systemd",
            UnitKind::Launchd => "launchd",
            UnitKind::Runit => "runit",
        }
    }
}

impl Host {
    pub const ALL: [Host; 4] = [
        Host::MacLaunchd,
        Host::LinuxSystemdUser,
        Host::LinuxSystemdSystem,
        Host::Termux,
    ];

    /// Stable kebab-case name, used on the CLI and in `CHUMP_PROVISION_HOST`.
    pub fn as_str(self) -> &'static str {
        match self {
            Host::MacLaunchd => "mac-launchd",
            Host::LinuxSystemdUser => "linux-systemd-user",
            Host::LinuxSystemdSystem => "linux-systemd-system",
            Host::Termux => "termux",
        }
    }

    /// Parse the kebab-case name or the Rust variant name.
    pub fn parse(s: &str) -> Option<Host> {
        let t = s.trim();
        Host::ALL.into_iter().find(|h| {
            h.as_str().eq_ignore_ascii_case(t) || format!("{h:?}").eq_ignore_ascii_case(t)
        })
    }

    /// The `platforms=` token this host matches in `scripts/ops/organ-manifest.txt`
    /// (the same vocabulary `organ_current_platform` in organ-manifest-lib.sh uses).
    pub fn platform(self) -> &'static str {
        match self {
            Host::MacLaunchd => "launchd",
            Host::LinuxSystemdUser | Host::LinuxSystemdSystem => "systemd",
            Host::Termux => "runit",
        }
    }

    /// The `run-scope=` value this host installs at.
    pub fn run_scope(self) -> RunScope {
        match self {
            Host::LinuxSystemdSystem => RunScope::System,
            Host::MacLaunchd | Host::LinuxSystemdUser | Host::Termux => RunScope::User,
        }
    }

    /// Can this host run an artifact of `kind`?
    pub fn supports(self, kind: UnitKind) -> bool {
        matches!(
            (self, kind),
            (Host::MacLaunchd, UnitKind::Launchd)
                | (Host::LinuxSystemdUser, UnitKind::Systemd)
                | (Host::LinuxSystemdSystem, UnitKind::Systemd)
                | (Host::Termux, UnitKind::Runit)
        )
    }

    /// Does this host run the local Rust pre-push test gate and therefore require
    /// `cargo-nextest` in `<home>/.cargo/bin` (INFRA-8572)?
    pub fn requires_cargo_nextest(self) -> bool {
        matches!(
            self,
            Host::MacLaunchd | Host::LinuxSystemdUser | Host::LinuxSystemdSystem
        )
    }
}

impl fmt::Display for Host {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Everything the detector looks at, as plain data so tests can fake it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Probe {
    /// `uname -s` (Darwin, Linux, ...).
    pub os: String,
    /// `$PREFIX` (Termux sets it to `/data/data/com.termux/files/usr`).
    pub prefix: Option<String>,
    pub has_launchctl: bool,
    pub has_systemctl: bool,
    /// Effective uid, `None` when it could not be read.
    pub euid: Option<u32>,
    /// Invoking user (`$USER`, else `id -un`).
    pub user: Option<String>,
    /// Invoking user's `$HOME`.
    pub home: Option<String>,
    /// `$XDG_CONFIG_HOME`.
    pub xdg_config_home: Option<String>,
    /// `CHUMP_RUN_USER` (from `~/.chump/node.env`): who system-scope units run as.
    pub run_user: Option<String>,
    /// uid owning the repo checkout, the fallback run user for system scope.
    pub repo_owner_uid: Option<u32>,
    /// `/etc/passwd` contents (empty on macOS, which uses Directory Services).
    pub passwd: Option<String>,
    /// `CHUMP_PROVISION_HOST`: explicit override (tests, or a node that wants
    /// to pin its variant).
    pub host_override: Option<String>,
    /// Does the Apple Silicon Homebrew prefix exist (`<prefix>/bin` is a dir)?
    /// Decides what `__BREW_PREFIX__` renders to on [`Host::MacLaunchd`]; see
    /// [`brew_prefix`]. INFRA-8194 slice 2.
    pub has_opt_homebrew: bool,
}

impl Probe {
    /// Read the live host. Every field degrades to `None`/`false` rather than
    /// failing, so `detect` decides what is missing.
    pub fn from_env() -> Probe {
        let env = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
        let cmd_out = |prog: &str, args: &[&str]| -> Option<String> {
            let o = std::process::Command::new(prog).args(args).output().ok()?;
            if !o.status.success() {
                return None;
            }
            let s = String::from_utf8_lossy(&o.stdout).trim().to_string();
            (!s.is_empty()).then_some(s)
        };
        let os = cmd_out("uname", &["-s"]).unwrap_or_else(|| {
            match std::env::consts::OS {
                "macos" => "Darwin",
                "linux" | "android" => "Linux",
                other => other,
            }
            .to_string()
        });
        let repo_owner_uid = env("CHUMP_REPO_ROOT").and_then(|r| owner_uid(Path::new(&r)));
        Probe {
            os,
            prefix: env("PREFIX"),
            has_launchctl: on_path("launchctl"),
            has_systemctl: on_path("systemctl"),
            euid: cmd_out("id", &["-u"]).and_then(|s| s.parse().ok()),
            user: env("USER").or_else(|| cmd_out("id", &["-un"])),
            home: env("HOME"),
            xdg_config_home: env("XDG_CONFIG_HOME"),
            run_user: env("CHUMP_RUN_USER"),
            repo_owner_uid,
            passwd: std::fs::read_to_string("/etc/passwd").ok(),
            host_override: env("CHUMP_PROVISION_HOST"),
            has_opt_homebrew: Path::new(APPLE_SILICON_BREW_PREFIX).join("bin").is_dir(),
        }
    }
}

/// Where Homebrew lives on Apple Silicon. The ONLY copy of this path the
/// provisioning layer keeps: templates write `__BREW_PREFIX__` and installers
/// ask [`brew_prefix`] (or its shell mirror `chump_brew_prefix` in
/// scripts/lib/host-paths.sh) instead of baking it in.
pub const APPLE_SILICON_BREW_PREFIX: &str = "/opt/homebrew";

/// Where Homebrew lives on Intel macOS, and the conventional local prefix
/// everywhere else (already on every default PATH, so a template that names
/// `__BREW_PREFIX__/bin` stays harmless on a host without brew).
pub const DEFAULT_BREW_PREFIX: &str = "/usr/local";

/// The Homebrew prefix `__BREW_PREFIX__` renders to on `host`.
///
/// INFRA-8194 slice 2: ~150 launchd plists and installers baked the Apple
/// Silicon prefix into their PATH, which is wrong on an Intel Mac and
/// meaningless on Linux (the INFRA-8112 brew-only-bootstrap class). The rule:
/// macOS with the Apple Silicon prefix present -> that prefix; anything else
/// -> [`DEFAULT_BREW_PREFIX`]. The shell mirror (`chump_brew_prefix`) applies
/// the same rule, so a pre-binary installer renders the same bytes.
pub fn brew_prefix(host: Host, p: &Probe) -> PathBuf {
    if host == Host::MacLaunchd && p.has_opt_homebrew {
        PathBuf::from(APPLE_SILICON_BREW_PREFIX)
    } else {
        PathBuf::from(DEFAULT_BREW_PREFIX)
    }
}

/// [`brew_prefix`] for a launchd plist rendered on THIS machine (callers that
/// only ever write macOS LaunchAgents, e.g. `chump onboard --schedule`).
pub fn local_mac_brew_prefix() -> PathBuf {
    let probe = Probe {
        has_opt_homebrew: Path::new(APPLE_SILICON_BREW_PREFIX).join("bin").is_dir(),
        ..Probe::default()
    };
    brew_prefix(Host::MacLaunchd, &probe)
}

fn on_path(prog: &str) -> bool {
    std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).any(|d| d.join(prog).is_file()))
        .unwrap_or(false)
}

#[cfg(unix)]
fn owner_uid(p: &Path) -> Option<u32> {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(p).ok().map(|m| m.uid())
}

#[cfg(not(unix))]
fn owner_uid(_p: &Path) -> Option<u32> {
    None
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DetectError {
    /// No supervisor this crate knows how to drive (Linux without systemd).
    NoSupervisor { os: String },
    /// `CHUMP_PROVISION_HOST` did not name a variant.
    BadOverride(String),
    /// Could not name the user a unit should run as.
    UnknownUser,
    /// Could not find the home directory for `user`.
    UnknownHome(String),
    /// Termux without `$PREFIX`.
    MissingPrefix,
}

impl fmt::Display for DetectError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DetectError::NoSupervisor { os } => write!(
                f,
                "no supported supervisor on this host (uname -s={os}; neither systemctl nor launchctl found, not Termux)"
            ),
            DetectError::BadOverride(v) => write!(
                f,
                "CHUMP_PROVISION_HOST={v:?} is not a host variant (expected one of: mac-launchd, linux-systemd-user, linux-systemd-system, termux)"
            ),
            DetectError::UnknownUser => {
                f.write_str("cannot determine the run user ($USER unset, no passwd entry for the euid)")
            }
            DetectError::UnknownHome(u) => write!(
                f,
                "no home directory known for user {u:?} (no passwd entry; set CHUMP_RUN_USER to an existing user)"
            ),
            DetectError::MissingPrefix => f.write_str("Termux host but $PREFIX is unset"),
        }
    }
}

impl std::error::Error for DetectError {}

/// Map a probe to exactly one host variant.
///
/// Order matters and mirrors `detect_host` in chump-node-install.sh: Termux is
/// checked first because it also reports `uname -s = Linux`; Darwin is launchd;
/// a host with `systemctl` is systemd, at system scope when running as root and
/// user scope otherwise.
pub fn detect(p: &Probe) -> Result<Host, DetectError> {
    if let Some(v) = p.host_override.as_deref().filter(|v| !v.trim().is_empty()) {
        return Host::parse(v).ok_or_else(|| DetectError::BadOverride(v.to_string()));
    }
    if p.prefix
        .as_deref()
        .is_some_and(|x| x.contains("com.termux"))
    {
        return Ok(Host::Termux);
    }
    if p.os == "Darwin" {
        return Ok(Host::MacLaunchd);
    }
    if p.has_systemctl {
        let is_root = match p.euid {
            Some(uid) => uid == 0,
            None => p.user.as_deref() == Some("root"),
        };
        return Ok(if is_root {
            Host::LinuxSystemdSystem
        } else {
            Host::LinuxSystemdUser
        });
    }
    if p.has_launchctl {
        return Ok(Host::MacLaunchd);
    }
    Err(DetectError::NoSupervisor { os: p.os.clone() })
}

/// What a detected host implies on disk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostPaths {
    pub host: Host,
    /// Where unit files / plists / runit service dirs are installed.
    pub unit_dir: PathBuf,
    /// Where the `chump` binary is linked so organ units resolve it.
    pub bin_dir: PathBuf,
    /// The run user's home (what `__HOME__` renders to).
    pub home: PathBuf,
    /// The user organs run as.
    pub user: String,
    /// The Homebrew prefix (what `__BREW_PREFIX__` renders to), see [`brew_prefix`].
    pub brew_prefix: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct PasswdEntry {
    name: String,
    uid: u32,
    home: String,
}

fn passwd_entries(passwd: Option<&str>) -> Vec<PasswdEntry> {
    passwd
        .unwrap_or("")
        .lines()
        .filter(|l| !l.starts_with('#'))
        .filter_map(|l| {
            let f: Vec<&str> = l.split(':').collect();
            if f.len() < 6 {
                return None;
            }
            Some(PasswdEntry {
                name: f[0].to_string(),
                uid: f[2].parse().ok()?,
                home: f[5].to_string(),
            })
        })
        .collect()
}

/// Derive unit dir, bin dir, home and user for `host` from the probe.
///
/// For [`Host::LinuxSystemdSystem`] the unit runs as the repo-owning RUN user,
/// not as root: `CHUMP_RUN_USER`, else the owner of the checkout, else the
/// invoking user. Its home comes from passwd. Nothing here ever synthesizes a
/// `/home/<name>` guess: an unknown home is an error, because a guessed home is
/// exactly how a unit ends up pointing at a directory that does not exist.
pub fn paths(host: Host, p: &Probe) -> Result<HostPaths, DetectError> {
    let entries = passwd_entries(p.passwd.as_deref());
    let by_uid = |uid: u32| entries.iter().find(|e| e.uid == uid);
    let by_name = |n: &str| entries.iter().find(|e| e.name == n);
    let invoking_user = p
        .user
        .clone()
        .filter(|u| !u.is_empty())
        .or_else(|| p.euid.and_then(|u| by_uid(u).map(|e| e.name.clone())));

    let user = match host.run_scope() {
        RunScope::System => p
            .run_user
            .clone()
            .filter(|u| !u.is_empty())
            .or_else(|| {
                p.repo_owner_uid
                    .and_then(|u| by_uid(u).map(|e| e.name.clone()))
            })
            .or_else(|| invoking_user.clone())
            .ok_or(DetectError::UnknownUser)?,
        RunScope::User => invoking_user.clone().ok_or(DetectError::UnknownUser)?,
    };

    let invoking_home = p.home.clone().filter(|h| !h.is_empty());
    let home = if Some(&user) == invoking_user.as_ref() && invoking_home.is_some() {
        invoking_home.clone().unwrap_or_default()
    } else if let Some(e) = by_name(&user) {
        e.home.clone()
    } else {
        return Err(DetectError::UnknownHome(user));
    };
    let home = PathBuf::from(home);

    let (unit_dir, bin_dir) = match host {
        Host::MacLaunchd => (home.join("Library/LaunchAgents"), home.join(".cargo/bin")),
        Host::LinuxSystemdUser => {
            let cfg = p
                .xdg_config_home
                .as_deref()
                .filter(|x| !x.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".config"));
            (cfg.join("systemd/user"), home.join(".cargo/bin"))
        }
        Host::LinuxSystemdSystem => (
            PathBuf::from("/etc/systemd/system"),
            home.join(".cargo/bin"),
        ),
        Host::Termux => {
            let prefix = p
                .prefix
                .as_deref()
                .filter(|x| !x.is_empty())
                .ok_or(DetectError::MissingPrefix)?;
            let prefix = PathBuf::from(prefix);
            (prefix.join("var/service"), prefix.join("bin"))
        }
    };

    Ok(HostPaths {
        host,
        unit_dir,
        bin_dir,
        home,
        user,
        brew_prefix: brew_prefix(host, p),
    })
}

/// One host literal found in a file or template.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finding {
    /// 1-based line number.
    pub line: usize,
    /// Which rule fired: `user-literal`, `home-literal`, `root-literal`, `homebrew-literal`.
    pub rule: &'static str,
    /// The offending text.
    pub text: String,
}

/// A line whose first non-blank character is `#`, other than a `#!` shebang.
/// The same rule the gate script applies (`grep -vE '^[[:space:]]*#([^!]|$)'`).
pub fn is_comment_line(line: &str) -> bool {
    let t = line.trim_start();
    t.starts_with('#') && !t.starts_with("#!")
}

fn is_ident_start(c: char) -> bool {
    c.is_ascii_alphabetic() || c == '_'
}

/// Scan `text` for the four host literals the R5 gate forbids. These are the
/// same rules `scripts/ci/test-provision-no-host-literals.sh` greps for:
///
/// * `user-literal`: `User=<name>` (a concrete name, not `User=$VAR` or a
///   placeholder), not preceded by an identifier character.
/// * `home-literal`: `/home/<name>`.
/// * `root-literal`: `/root/`.
/// * `homebrew-literal`: `/opt/homebrew`.
///
/// A comment line (first non-blank character `#`) is skipped: it executes
/// nothing, in a shell script, a systemd unit or YAML alike (INFRA-8194 slice
/// 2; incident receipts such as "the old unit ran ~root's checkout" live in
/// comments and are not host assumptions). A `#!` shebang is NOT a comment:
/// `#!/opt/homebrew/bin/bash` pins the interpreter to one machine, so it is
/// still flagged. Quoted text inside code is never skipped, because a quoted
/// string is usually a live path.
pub fn find_host_literals(text: &str) -> Vec<Finding> {
    let mut out = Vec::new();
    for (i, line) in text.lines().enumerate() {
        let n = i + 1;
        if is_comment_line(line) {
            continue;
        }
        let mut push = |rule: &'static str| {
            out.push(Finding {
                line: n,
                rule,
                text: line.trim().to_string(),
            })
        };
        let user_hit = line.match_indices("User=").any(|(idx, _)| {
            let before_ok = line[..idx]
                .chars()
                .next_back()
                .is_none_or(|c| !(c.is_ascii_alphanumeric() || c == '_'));
            let after_ok = line[idx + "User=".len()..]
                .chars()
                .next()
                .is_some_and(is_ident_start);
            before_ok && after_ok
        });
        if user_hit {
            push("user-literal");
        }
        let home_hit = line.match_indices("/home/").any(|(idx, _)| {
            line[idx + "/home/".len()..]
                .chars()
                .next()
                .is_some_and(|c| c.is_ascii_lowercase() || c == '_')
        });
        if home_hit {
            push("home-literal");
        }
        if line.contains("/root/") {
            push("root-literal");
        }
        if line.contains("/opt/homebrew") {
            push("homebrew-literal");
        }
    }
    out
}

/// Host values a template's placeholders resolve to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RenderCtx {
    pub home: PathBuf,
    pub repo_root: PathBuf,
    pub bin_dir: PathBuf,
    /// Who a system-scope unit runs as (written as `User=`).
    pub user: String,
    /// The Homebrew prefix (`__BREW_PREFIX__`), see [`brew_prefix`].
    pub brew_prefix: PathBuf,
}

impl RenderCtx {
    pub fn from_paths(p: &HostPaths, repo_root: impl Into<PathBuf>) -> RenderCtx {
        RenderCtx {
            home: p.home.clone(),
            repo_root: repo_root.into(),
            bin_dir: p.bin_dir.clone(),
            user: p.user.clone(),
            brew_prefix: p.brew_prefix.clone(),
        }
    }
}

/// The placeholders a template may use. Same tokens the shell mirror
/// (`organ_unit_host_rewrite`) substitutes.
pub const PLACEHOLDERS: [&str; 5] = [
    "__HOME__",
    "__REPO_ROOT__",
    "__BIN_DIR__",
    "__NODE_ENV__",
    "__BREW_PREFIX__",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RenderError {
    UnknownKind(String),
    HostMismatch {
        host: Host,
        kind: UnitKind,
    },
    HostLiterals(Vec<Finding>),
    /// `%h` in a system-scope systemd unit resolves to the manager's home
    /// (`/root`), not the `User=` home (INFRA-3647).
    SystemScopeHomeSpecifier {
        line: usize,
    },
    UnresolvedPlaceholder(Vec<String>),
}

impl fmt::Display for RenderError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RenderError::UnknownKind(n) => write!(
                f,
                "cannot tell what supervisor {n:?} is for (expected .service/.timer/.socket/.path/.target/.conf, .plist, or a runit `run`)"
            ),
            RenderError::HostMismatch { host, kind } => write!(
                f,
                "host {host} cannot run a {} artifact; the organ manifest's platforms= should scope it off this host",
                kind.as_str()
            ),
            RenderError::HostLiterals(found) => {
                write!(f, "template carries host literals (use __HOME__/__REPO_ROOT__/__BIN_DIR__/__NODE_ENV__/__BREW_PREFIX__; User= is injected by the renderer):")?;
                for x in found {
                    write!(f, "\n  line {}: [{}] {}", x.line, x.rule, x.text)?;
                }
                Ok(())
            }
            RenderError::SystemScopeHomeSpecifier { line } => write!(
                f,
                "line {line}: %h in a system-scope unit expands to the manager's home (/root) regardless of User= (INFRA-3647); use __HOME__"
            ),
            RenderError::UnresolvedPlaceholder(v) => {
                write!(f, "unresolved placeholder(s): {}", v.join(", "))
            }
        }
    }
}

impl std::error::Error for RenderError {}

fn unresolved_placeholders(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let bytes = text.as_bytes();
    let mut i = 0;
    while i + 1 < bytes.len() {
        if bytes[i] == b'_' && bytes[i + 1] == b'_' {
            let start = i + 2;
            let mut j = start;
            while j < bytes.len()
                && (bytes[j].is_ascii_uppercase() || bytes[j].is_ascii_digit() || bytes[j] == b'_')
            {
                j += 1;
            }
            // A token is __UPPER__: at least one char, ends in "__", first char a letter.
            if j > start + 2 && bytes[start].is_ascii_uppercase() && &bytes[j - 2..j] == b"__" {
                let tok = &text[i..j];
                if !out.iter().any(|t| t == tok) {
                    out.push(tok.to_string());
                }
                i = j;
                continue;
            }
        }
        i += 1;
    }
    out
}

/// Units whose JOB needs root at system scope (RESILIENT-374: the deploy organ
/// writes /etc/systemd/system). The renderer writes `User=root` for these
/// instead of the run user; their paths still resolve to the run user's home.
/// Same set as `_KEEP_ROOT_ORGANS` in install-helsinki-atc.sh (the system-scope
/// placer, which passes keep_root=1 to the shell mirror; the reconcile organ
/// joined it so it can enforce the manifest). Kept by name so the template
/// itself carries no `User=` literal (INFRA-8194). A user-scope install never
/// gets `User=` at all, root or otherwise.
pub const KEEP_ROOT_UNITS: [&str; 4] = [
    "chump-organ-deploy.service",
    "chump-organ-deploy.timer",
    "chump-organ-reconcile.service",
    "chump-organ-reconcile.timer",
];

/// Is `name` (a path or file name) one of [`KEEP_ROOT_UNITS`]?
pub fn is_keep_root_unit(name: &str) -> bool {
    let base = Path::new(name)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(name);
    KEEP_ROOT_UNITS.contains(&base)
}

/// Render `template` (named `name`, used to classify its kind) for `host`.
pub fn render(
    name: &str,
    template: &str,
    host: Host,
    ctx: &RenderCtx,
) -> Result<String, RenderError> {
    let kind =
        UnitKind::from_name(name).ok_or_else(|| RenderError::UnknownKind(name.to_string()))?;
    if !host.supports(kind) {
        return Err(RenderError::HostMismatch { host, kind });
    }
    let found = find_host_literals(template);
    if !found.is_empty() {
        return Err(RenderError::HostLiterals(found));
    }
    if host == Host::LinuxSystemdSystem {
        for (i, line) in template.lines().enumerate() {
            let t = line.trim_start();
            if !t.starts_with('#') && t.contains("%h") {
                return Err(RenderError::SystemScopeHomeSpecifier { line: i + 1 });
            }
        }
    }

    let home = ctx.home.to_string_lossy().trim_end_matches('/').to_string();
    let repo = ctx
        .repo_root
        .to_string_lossy()
        .trim_end_matches('/')
        .to_string();
    let bin = ctx
        .bin_dir
        .to_string_lossy()
        .trim_end_matches('/')
        .to_string();
    let brew = ctx
        .brew_prefix
        .to_string_lossy()
        .trim_end_matches('/')
        .to_string();
    let node_env = format!("{home}/.chump/node.env");
    let mut out = template
        .replace("__HOME__", &home)
        .replace("__REPO_ROOT__", &repo)
        .replace("__BIN_DIR__", &bin)
        .replace("__NODE_ENV__", &node_env)
        .replace("__BREW_PREFIX__", &brew);

    let left = unresolved_placeholders(&out);
    if !left.is_empty() {
        return Err(RenderError::UnresolvedPlaceholder(left));
    }

    // The ONE place User= is written. A user manager cannot switch identity
    // (216/GROUP, 217/USER), so only the system scope gets it.
    if host == Host::LinuxSystemdSystem && kind == UnitKind::Systemd {
        let mut lines: Vec<String> = out.lines().map(str::to_string).collect();
        if let Some(pos) = lines.iter().position(|l| l.trim() == "[Service]") {
            let user = if is_keep_root_unit(name) {
                "root"
            } else {
                ctx.user.as_str()
            };
            lines.insert(pos + 1, format!("User={user}"));
            let trailing_newline = out.ends_with('\n');
            out = lines.join("\n");
            if trailing_newline {
                out.push('\n');
            }
        }
    }
    Ok(out)
}

/// Prebuilt nextest release URL for `(host, arch)` (INFRA-8572).
pub fn cargo_nextest_archive_url(host: Host, arch: &str) -> Option<&'static str> {
    match host {
        Host::MacLaunchd => Some("https://get.nexte.st/latest/mac"),
        Host::LinuxSystemdUser | Host::LinuxSystemdSystem => match arch {
            "aarch64" | "arm64" => Some("https://get.nexte.st/latest/linux-arm"),
            "x86_64" | "amd64" => Some("https://get.nexte.st/latest/linux"),
            _ => None,
        },
        Host::Termux => None,
    }
}

/// How `chump-provision` converges `cargo-nextest` on a host (INFRA-8572).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NextestProvisionPlan {
    /// Host does not run the local Rust test gate (e.g. Termux).
    NotApplicable { host: Host },
    /// `cargo-nextest` is already installed at `bin`.
    AlreadyInstalled { bin: PathBuf },
    /// Install `cargo-nextest` into `bin` (prebuilt archive URL if available,
    /// falling back to `cargo install cargo-nextest --locked`).
    Install {
        bin: PathBuf,
        archive_url: Option<&'static str>,
        cargo_fallback: [&'static str; 4],
    },
}

/// Compute the idempotent `cargo-nextest` provisioning plan for `host` (INFRA-8572).
pub fn plan_cargo_nextest(
    host: Host,
    paths: &HostPaths,
    arch: &str,
    already_installed_at: Option<PathBuf>,
) -> NextestProvisionPlan {
    if !host.requires_cargo_nextest() {
        return NextestProvisionPlan::NotApplicable { host };
    }
    if let Some(bin) = already_installed_at {
        return NextestProvisionPlan::AlreadyInstalled { bin };
    }
    let bin = paths.bin_dir.join("cargo-nextest");
    if bin.is_file() {
        return NextestProvisionPlan::AlreadyInstalled { bin };
    }
    NextestProvisionPlan::Install {
        bin,
        archive_url: cargo_nextest_archive_url(host, arch),
        cargo_fallback: ["cargo", "install", "cargo-nextest", "--locked"],
    }
}

/// Scan an ALREADY-RENDERED installed unit for foreign/illegal host literals
/// relative to `(expected_home, host)` (INFRA-8589).
///
/// Unlike [`find_host_literals`] (which checks unrendered repo templates where
/// ANY `/home/<name>` is forbidden), an installed unit legitimately contains the
/// host's own `expected_home` (e.g. `/home/ubuntu`). This scanner flags:
/// - `foreign-home-literal`: `/home/<other>` where `/home/<other>` != `expected_home`
/// - `foreign-users-literal`: `/Users/<name>` on non-MacLaunchd, or != `expected_home` on MacLaunchd
/// - `root-literal`: `/root/` when `expected_home` != `/root`
/// - `homebrew-literal`: `/opt/homebrew` on a Linux or Termux host
/// - `user-literal`: `User=<name>` in a `LinuxSystemdUser` unit
pub fn find_installed_unit_foreign_literals(
    text: &str,
    expected_home: &Path,
    host: Host,
) -> Vec<Finding> {
    let expected = expected_home.to_string_lossy();
    let expected = expected.trim_end_matches('/');
    let mut out = Vec::new();
    for (i, line) in text.lines().enumerate() {
        let n = i + 1;
        if is_comment_line(line) {
            continue;
        }
        let mut push = |rule: &'static str| {
            out.push(Finding {
                line: n,
                rule,
                text: line.trim().to_string(),
            })
        };
        if host == Host::LinuxSystemdUser {
            let user_hit = line.match_indices("User=").any(|(idx, _)| {
                let before_ok = line[..idx]
                    .chars()
                    .next_back()
                    .is_none_or(|c| !(c.is_ascii_alphanumeric() || c == '_'));
                let after_ok = line[idx + "User=".len()..]
                    .chars()
                    .next()
                    .is_some_and(is_ident_start);
                before_ok && after_ok
            });
            if user_hit {
                push("user-literal");
            }
        }
        for (idx, _) in line.match_indices("/home/") {
            let rest = &line[idx + "/home/".len()..];
            let uname: String = rest
                .chars()
                .take_while(|c| {
                    c.is_ascii_lowercase() || c.is_ascii_digit() || *c == '_' || *c == '-'
                })
                .collect();
            if !uname.is_empty() {
                let candidate = format!("/home/{uname}");
                if candidate != expected {
                    push("foreign-home-literal");
                    break;
                }
            }
        }
        for (idx, _) in line.match_indices("/Users/") {
            let rest = &line[idx + "/Users/".len()..];
            let uname: String = rest
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
                .collect();
            if !uname.is_empty() {
                let candidate = format!("/Users/{uname}");
                if host != Host::MacLaunchd || candidate != expected {
                    push("foreign-users-literal");
                    break;
                }
            }
        }
        if expected != "/root" && line.contains("/root/") {
            push("root-literal");
        }
        if host != Host::MacLaunchd && line.contains("/opt/homebrew") {
            push("homebrew-literal");
        }
    }
    out
}

/// Summary of `rerender_installed_units` (INFRA-8589).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RerenderReport {
    pub scanned: usize,
    pub matched_templates: usize,
    pub foreign_literal_units: Vec<String>,
    pub rerendered: Vec<String>,
}

/// Template search directories relative to `repo_root` (INFRA-8589).
pub const TEMPLATE_REL_DIRS: [&str; 6] = [
    "scripts/dispatch",
    "scripts/ops/systemd",
    "scripts/ops",
    "scripts/setup",
    "launchd",
    "scripts/plists",
];

/// Re-render installed units in `unit_dir` from their matching repo templates
/// under `repo_root`, replacing any unit that carries a foreign host literal or
/// has drifted from its rendered template (INFRA-8589).
pub fn rerender_installed_units(
    unit_dir: &Path,
    repo_root: &Path,
    host: Host,
    ctx: &RenderCtx,
    dry_run: bool,
) -> std::io::Result<RerenderReport> {
    let mut report = RerenderReport::default();
    if !unit_dir.is_dir() {
        return Ok(report);
    }
    let mut entries: Vec<PathBuf> = std::fs::read_dir(unit_dir)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.is_file())
        .collect();
    entries.sort();

    for installed_path in entries {
        let Some(fname) = installed_path.file_name().and_then(|s| s.to_str()) else {
            continue;
        };
        let Some(kind) = UnitKind::from_name(fname) else {
            continue;
        };
        if host.platform() != kind.as_str() {
            continue;
        }
        report.scanned += 1;
        let installed_text = std::fs::read_to_string(&installed_path)?;
        let has_foreign =
            !find_installed_unit_foreign_literals(&installed_text, &ctx.home, host).is_empty();
        if has_foreign {
            report.foreign_literal_units.push(fname.to_string());
        }
        let tmpl_path = TEMPLATE_REL_DIRS
            .iter()
            .map(|d| repo_root.join(d).join(fname))
            .find(|p| p.is_file());
        let Some(tmpl_path) = tmpl_path else {
            continue;
        };
        report.matched_templates += 1;
        let tmpl_text = std::fs::read_to_string(&tmpl_path)?;
        let Ok(rendered) = render(fname, &tmpl_text, host, ctx) else {
            continue;
        };
        if has_foreign || installed_text != rendered {
            if !dry_run {
                std::fs::write(&installed_path, &rendered)?;
            }
            report.rerendered.push(fname.to_string());
        }
    }
    Ok(report)
}

#[cfg(test)]
mod tests;
