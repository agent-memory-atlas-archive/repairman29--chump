//! node.env format invariant (INFRA-8588, Phase R R5).
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
//! The fix is a single systemd-compatible form: **bare `KEY=VALUE`, never
//! `export`**. bash consumers recover `export` semantics by sourcing under
//! `set -a`. This module owns the invariant (Rust-owns-invariants): one
//! renderer that only emits bare lines, and one validator the converge /
//! fleet-doctor check and the render test both lean on.

/// Render one node.env assignment in the single systemd-compatible form:
/// bare `KEY=VALUE`, no `export` prefix. Values are written verbatim (node.env
/// values are shell/systemd tokens — paths, ints, enum words — never quoted).
pub fn render_line(key: &str, value: &str) -> String {
    format!("{key}={value}")
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
}
