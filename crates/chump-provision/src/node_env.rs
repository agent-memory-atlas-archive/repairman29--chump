//! node.env format invariant (INFRA-8588, RESILIENT-1684, INFRA-8104).
//!
//! `~/.chump/node.env` is read two ways: bash organs `source` it, and systemd
//! units name it as `EnvironmentFile=`. systemd's EnvironmentFile parser is NOT
//! a shell — it accepts only bare `KEY=VALUE` and logs
//! `Ignoring invalid environment assignment export KEY=VALUE` for every line
//! that starts with `export`. The 2026-10-18 incident: node.env mixed
//! `export CHUMP_NODE_WORK_ENABLED=0` (hand/installer-written) with bare
//! `CHUMP_MAX_CONCURRENT_CARGO_JOBS=2` lines, so EnvironmentFile units (worker,
//! converge, gap-close) silently ignored the pause knobs the architect set,
//! while bash-sourcing organs honored them — a split-brain node config.
//!
//! Additionally (RESILIENT-1684 + INFRA-8104), team-store keys
//! (`CHUMP_STORE_BACKEND`, `CHUMP_TEAM_URL`, `CHUMP_TEAM_API_KEY`) must only be
//! emitted as bare `KEY=VALUE` lines when a store actually listens at
//! `CHUMP_TEAM_URL` (or an explicit listener check passes), never flipped blind.
//!
//! The fix is a single systemd-compatible form: **bare `KEY=VALUE`, never
//! `export`**. bash consumers recover `export` semantics by sourcing under
//! `set -a`. This module owns the invariant (Rust-owns-invariants): one
//! renderer that only emits bare lines, a sanitizer/validator for `node.env`,
//! and systemd vs. shell parsers proving both consumers see identical keys.

use std::collections::BTreeMap;
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

/// Keys that configure the remote team gap store and must only be emitted when
/// a store listener is reachable at `CHUMP_TEAM_URL` (RESILIENT-1684 / INFRA-8104).
pub const TEAM_STORE_KEYS: &[&str] = &[
    "CHUMP_STORE_BACKEND",
    "CHUMP_TEAM_URL",
    "CHUMP_TEAM_API_KEY",
];

/// Default systemd worker unit prefix for `node-orchestrator.sh` (RESILIENT-1708).
pub const DEFAULT_ORCH_WORKER_UNIT: &str = "chump-worker@";

/// Legacy hardcoded CJ worker unit prefix that must never be defaulted on other nodes.
pub const LEGACY_CJ_WORKER_UNIT: &str = "chump-cj-worker";

/// Resolve the per-node orchestrator worker unit for `CHUMP_ORCH_WORKER_UNIT`:
/// uses the node profile's configured worker unit when non-empty and not the
/// legacy `chump-cj-worker` CJ-ism, otherwise defaults to `chump-worker@`
/// (RESILIENT-1708).
pub fn resolve_orch_worker_unit(profile_unit: Option<&str>) -> &str {
    match profile_unit.map(str::trim).filter(|u| !u.is_empty()) {
        Some(u) if !u.starts_with(LEGACY_CJ_WORKER_UNIT) => u,
        _ => DEFAULT_ORCH_WORKER_UNIT,
    }
}

/// Returns `true` if `key` is one of the remote team-store configuration keys
/// that require a live listener check before emission into `node.env`.
pub fn is_team_store_key(key: &str) -> bool {
    TEAM_STORE_KEYS.contains(&key)
}

/// Probe whether a TCP listener accepts connections at the host:port named in
/// `team_url` (e.g. `http://127.0.0.1:8788` or `http://localhost:8788/api`).
/// Returns `false` if the URL cannot be parsed or no listener responds within `timeout`.
pub fn probe_team_url_listener(team_url: &str, timeout: Duration) -> bool {
    let trimmed = team_url.trim();
    if trimmed.is_empty() {
        return false;
    }
    let (rest, default_port) = if let Some(r) = trimmed.strip_prefix("http://") {
        (r, 80u16)
    } else if let Some(r) = trimmed.strip_prefix("https://") {
        (r, 443u16)
    } else {
        (trimmed, 80u16)
    };
    let authority = rest.split('/').next().unwrap_or("");
    let host_port = authority.rsplit('@').next().unwrap_or(authority);
    if host_port.is_empty() {
        return false;
    }
    let addr_str = if host_port.starts_with('[') {
        if host_port.contains("]:") {
            host_port.to_string()
        } else {
            format!("{host_port}:{default_port}")
        }
    } else if host_port.contains(':') {
        host_port.to_string()
    } else {
        format!("{host_port}:{default_port}")
    };
    let Ok(addrs) = addr_str.to_socket_addrs() else {
        return false;
    };
    for addr in addrs {
        if TcpStream::connect_timeout(&addr, timeout).is_ok() {
            return true;
        }
    }
    false
}

/// Render one node.env assignment in the single systemd-compatible form:
/// bare `KEY=VALUE`, no `export` prefix. Values are written verbatim (node.env
/// values are shell/systemd tokens — paths, ints, enum words — never quoted).
pub fn render_line(key: &str, value: &str) -> String {
    let clean_key = key.trim().strip_prefix("export").map_or(key.trim(), |r| {
        if r.starts_with([' ', '\t']) {
            r.trim_start()
        } else {
            key.trim()
        }
    });
    format!("{clean_key}={value}")
}

/// Render a full `node.env` document from `(key, value)` pairs in bare `KEY=VALUE`
/// form (no `export ` prefix). Team-store keys (`CHUMP_STORE_BACKEND`,
/// `CHUMP_TEAM_URL`, `CHUMP_TEAM_API_KEY`) are only emitted when `store_listening`
/// is `true` (RESILIENT-1684 / INFRA-8104). Always emits `CHUMP_ORCH_WORKER_UNIT=<unit>`
/// using the node profile's worker unit or defaulting to `chump-worker@`, never
/// a hardcoded `chump-cj-worker` default (RESILIENT-1708).
pub fn render_node_env(pairs: &[(&str, &str)], store_listening: bool) -> String {
    let mut out = String::new();
    let mut saw_worker_unit = false;
    for &(raw_key, val) in pairs {
        let key = raw_key
            .trim()
            .strip_prefix("export")
            .map_or(raw_key.trim(), |r| {
                if r.starts_with([' ', '\t']) {
                    r.trim_start()
                } else {
                    raw_key.trim()
                }
            });
        if is_team_store_key(key) && !store_listening {
            continue;
        }
        if key == "CHUMP_ORCH_WORKER_UNIT" {
            saw_worker_unit = true;
            let unit = resolve_orch_worker_unit(Some(val));
            out.push_str(&render_line(key, unit));
            out.push('\n');
            continue;
        }
        out.push_str(&render_line(key, val));
        out.push('\n');
    }
    if !saw_worker_unit {
        out.push_str(&render_line(
            "CHUMP_ORCH_WORKER_UNIT",
            DEFAULT_ORCH_WORKER_UNIT,
        ));
        out.push('\n');
    }
    out
}

/// Normalize an existing `node.env` text into canonical bare `KEY=VALUE` lines:
/// - Strips any leading `export ` prefix on assignments.
/// - Preserves comments and blank lines.
/// - Drops `CHUMP_STORE_BACKEND`, `CHUMP_TEAM_URL`, and `CHUMP_TEAM_API_KEY`
///   assignments when `store_listening` is `false` so they are never flipped blind.
/// - Rewrites any legacy `CHUMP_ORCH_WORKER_UNIT=chump-cj-worker` to `chump-worker@`
///   (RESILIENT-1708).
pub fn sanitize_node_env(contents: &str, store_listening: bool) -> String {
    let mut out = String::new();
    for line in contents.lines() {
        let trimmed = line.trim_start();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            out.push_str(line);
            out.push('\n');
            continue;
        }
        let body = if let Some(rest) = trimmed.strip_prefix("export") {
            if rest.starts_with([' ', '\t']) {
                rest.trim_start()
            } else {
                trimmed
            }
        } else {
            trimmed
        };
        if let Some((k, v)) = body.split_once('=') {
            let key = k.trim();
            if is_team_store_key(key) && !store_listening {
                continue;
            }
            let raw_val = strip_matching_quotes(v.trim());
            let val = if key == "CHUMP_ORCH_WORKER_UNIT" {
                resolve_orch_worker_unit(Some(raw_val))
            } else {
                raw_val
            };
            out.push_str(&render_line(key, val));
            out.push('\n');
        } else {
            out.push_str(line);
            out.push('\n');
        }
    }
    out
}

fn is_valid_env_ident(s: &str) -> bool {
    let mut chars = s.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if !(first.is_ascii_alphabetic() || first == '_') {
        return false;
    }
    chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

fn strip_matching_quotes(s: &str) -> &str {
    if s.len() >= 2
        && ((s.starts_with('"') && s.ends_with('"')) || (s.starts_with('\'') && s.ends_with('\'')))
    {
        &s[1..s.len() - 1]
    } else {
        s
    }
}

/// Parse `contents` according to systemd `EnvironmentFile=` rules:
/// - Blank lines and lines starting with `#` or `;` are ignored.
/// - Assignments must be bare `KEY=VALUE` where `KEY` is a valid POSIX identifier
///   with no `export ` prefix (systemd rejects `export KEY=VALUE` because `export KEY`
///   contains whitespace and is not a valid variable name).
pub fn parse_systemd_env_file(contents: &str) -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    for line in contents.lines() {
        let t = line.trim();
        if t.is_empty() || t.starts_with('#') || t.starts_with(';') {
            continue;
        }
        let Some((key, raw_val)) = t.split_once('=') else {
            continue;
        };
        if !is_valid_env_ident(key) {
            // Rejects `export KEY` and any other non-identifier left-hand side.
            continue;
        }
        map.insert(key.to_string(), strip_matching_quotes(raw_val).to_string());
    }
    map
}

/// Parse `contents` according to POSIX/bash `set -a; source node.env` rules:
/// - Accepts both `export KEY=VALUE` and bare `KEY=VALUE`.
pub fn parse_shell_env_file(contents: &str) -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    for line in contents.lines() {
        let t = line.trim();
        if t.is_empty() || t.starts_with('#') {
            continue;
        }
        let body = if let Some(rest) = t.strip_prefix("export") {
            if rest.starts_with([' ', '\t']) {
                rest.trim_start()
            } else {
                t
            }
        } else {
            t
        };
        let Some((key, raw_val)) = body.split_once('=') else {
            continue;
        };
        if !is_valid_env_ident(key) {
            continue;
        }
        map.insert(key.to_string(), strip_matching_quotes(raw_val).to_string());
    }
    map
}

/// 1-indexed line numbers (with the offending text) of every `node.env` line
/// that uses an `export` prefix — the form systemd's EnvironmentFile rejects.
/// A converge / fleet-doctor check flags a non-empty result; the render test
/// asserts an empty one. Comment (`#`) and blank lines are ignored.
pub fn export_violations(contents: &str) -> Vec<(usize, String)> {
    contents
        .lines()
        .enumerate()
        .filter_map(|(i, line)| {
            let t = line.trim_start();
            if t.starts_with('#') || t.is_empty() {
                return None;
            }
            // Match `export KEY=` — `export` followed by whitespace, i.e. a
            // prefix systemd would reject (not a KEY literally named "export…").
            let rest = t.strip_prefix("export")?;
            if rest.starts_with([' ', '\t']) {
                Some((i + 1, line.to_string()))
            } else {
                None
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    #[test]
    fn render_line_is_bare_no_export() {
        assert_eq!(
            render_line("CHUMP_NODE_MODE", "paused"),
            "CHUMP_NODE_MODE=paused"
        );
        assert_eq!(
            render_line("CHUMP_NODE_WORK_ENABLED", "0"),
            "CHUMP_NODE_WORK_ENABLED=0"
        );
        assert_eq!(
            render_line("export CHUMP_RUN_USER", "ubuntu"),
            "CHUMP_RUN_USER=ubuntu"
        );
        // A rendered node.env of only render_line() output has zero violations.
        let rendered = [
            render_line("CHUMP_STATE_DIR", "/home/ubuntu/.chump"),
            render_line("CHUMP_NODE_MODE", "control-plane"),
            render_line("CHUMP_NODE_WORK_ENABLED", "0"),
        ]
        .join("\n");
        assert!(export_violations(&rendered).is_empty());
    }

    #[test]
    fn systemd_and_shell_see_identical_keys_and_mutant_with_export_fails() {
        let rendered = render_node_env(
            &[
                ("CHUMP_STATE_DIR", "/home/ubuntu/.chump"),
                ("CHUMP_NODE_ROLE", "muscle"),
                ("CHUMP_RUN_USER", "ubuntu"),
                ("CHUMP_NODE_WORK_ENABLED", "1"),
                ("CHUMP_STORE_BACKEND", "team"),
                ("CHUMP_TEAM_URL", "http://127.0.0.1:8788"),
                ("CHUMP_TEAM_API_KEY", "test-team-key"),
            ],
            true,
        );
        assert!(export_violations(&rendered).is_empty());
        let systemd_env = parse_systemd_env_file(&rendered);
        let shell_env = parse_shell_env_file(&rendered);
        assert_eq!(
            systemd_env, shell_env,
            "every key a shell caller sees must be visible to a systemd EnvironmentFile unit"
        );
        assert_eq!(
            systemd_env.get("CHUMP_STORE_BACKEND").map(String::as_str),
            Some("team")
        );

        // Mutant: add `export ` to one line -> shell still sees it, systemd drops it.
        let mutant = format!("{rendered}export CHUMP_MUTANT_PAUSE=1\n");
        assert!(!export_violations(&mutant).is_empty());
        let mutant_systemd = parse_systemd_env_file(&mutant);
        let mutant_shell = parse_shell_env_file(&mutant);
        assert!(mutant_shell.contains_key("CHUMP_MUTANT_PAUSE"));
        assert!(
            !mutant_systemd.contains_key("CHUMP_MUTANT_PAUSE"),
            "systemd parser must reject `export KEY=VALUE` line"
        );
        assert_ne!(
            mutant_systemd, mutant_shell,
            "mutant that adds `export ` must break shell/systemd parity"
        );
    }

    #[test]
    fn team_store_keys_require_live_listener_never_flipped_blind() {
        let raw = "\
# node.env
export CHUMP_NODE_ROLE=muscle
export CHUMP_RUN_USER=ubuntu
export CHUMP_STORE_BACKEND=team
export CHUMP_TEAM_URL=http://127.0.0.1:8788
export CHUMP_TEAM_API_KEY=secret-team-key
";
        // When store is NOT listening, team-store keys are omitted and export is stripped.
        let sanitized_down = sanitize_node_env(raw, false);
        assert!(export_violations(&sanitized_down).is_empty());
        let env_down = parse_systemd_env_file(&sanitized_down);
        assert_eq!(env_down, parse_shell_env_file(&sanitized_down));
        assert_eq!(
            env_down.get("CHUMP_NODE_ROLE").map(String::as_str),
            Some("muscle")
        );
        assert!(!env_down.contains_key("CHUMP_STORE_BACKEND"));
        assert!(!env_down.contains_key("CHUMP_TEAM_URL"));
        assert!(!env_down.contains_key("CHUMP_TEAM_API_KEY"));

        // When store IS listening, team-store keys are emitted in bare KEY=VALUE form.
        let sanitized_up = sanitize_node_env(raw, true);
        assert!(export_violations(&sanitized_up).is_empty());
        let env_up = parse_systemd_env_file(&sanitized_up);
        assert_eq!(env_up, parse_shell_env_file(&sanitized_up));
        assert_eq!(
            env_up.get("CHUMP_STORE_BACKEND").map(String::as_str),
            Some("team")
        );
        assert_eq!(
            env_up.get("CHUMP_TEAM_URL").map(String::as_str),
            Some("http://127.0.0.1:8788")
        );
        assert_eq!(
            env_up.get("CHUMP_TEAM_API_KEY").map(String::as_str),
            Some("secret-team-key")
        );
    }

    #[test]
    fn probe_team_url_listener_detects_bound_vs_closed_port() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind ephemeral port");
        let port = listener.local_addr().expect("local_addr").port();
        let live_url = format!("http://127.0.0.1:{port}/api/gaps");
        assert!(probe_team_url_listener(
            &live_url,
            Duration::from_millis(200)
        ));
        drop(listener);
        assert!(!probe_team_url_listener(
            &live_url,
            Duration::from_millis(100)
        ));
    }

    #[test]
    fn export_violations_flags_export_lines_only() {
        let contents = "\
# a comment
CHUMP_STATE_DIR=/home/ubuntu/.chump
export CHUMP_NODE_WORK_ENABLED=0
CHUMP_NODE_MODE=control-plane
   export CHUMP_RUN_USER=ubuntu

CHUMP_MAX_CONCURRENT_CARGO_JOBS=2
";
        let v = export_violations(contents);
        assert_eq!(v.len(), 2, "two export lines, got {v:?}");
        assert_eq!(v[0].0, 3);
        assert_eq!(v[1].0, 5);
    }

    #[test]
    fn export_violations_ignores_key_named_exportish() {
        // A key that merely starts with the letters "export" (no space) is a
        // legal bare assignment, not an `export ` statement.
        let contents = "exported_at=123\nexport_count=4\n";
        assert!(export_violations(contents).is_empty());
    }

    #[test]
    fn render_node_env_emits_orch_worker_unit_and_rejects_cj_ism_resilient_1708() {
        // 1. Default when omitted -> chump-worker@.
        let default_rendered = render_node_env(&[("CHUMP_NODE_ROLE", "muscle")], false);
        let env_default = parse_systemd_env_file(&default_rendered);
        assert_eq!(
            env_default
                .get("CHUMP_ORCH_WORKER_UNIT")
                .map(String::as_str),
            Some("chump-worker@")
        );

        // 2. Explicit profile unit (e.g. cuphead's chump-node1-worker) is preserved.
        let custom_rendered = render_node_env(
            &[
                ("CHUMP_NODE_ROLE", "muscle"),
                ("CHUMP_ORCH_WORKER_UNIT", "chump-node1-worker"),
            ],
            false,
        );
        let env_custom = parse_systemd_env_file(&custom_rendered);
        assert_eq!(
            env_custom.get("CHUMP_ORCH_WORKER_UNIT").map(String::as_str),
            Some("chump-node1-worker")
        );

        // 3. Legacy CJ-ism `chump-cj-worker` is replaced with `chump-worker@`.
        let cj_rendered = render_node_env(&[("CHUMP_ORCH_WORKER_UNIT", "chump-cj-worker")], false);
        let env_cj = parse_systemd_env_file(&cj_rendered);
        assert_eq!(
            env_cj.get("CHUMP_ORCH_WORKER_UNIT").map(String::as_str),
            Some("chump-worker@")
        );
    }
}
