use anyhow::{Context, Result};
use chrono::Utc;
/// RESILIENT-1614: Node pause/resume commands to enforce paused mode as an invariant.
/// Makes fleet pause honored by all work organs (node-converge, organ-reconcile,
/// organ-deploy, paramedic, process-organ-heal, self-doctor, worker loop).
///
/// `chump node pause --reason "reason"` and `chump node resume` manage the pause state
/// by writing to node.env + emitting lifecycle events.
use std::fs;
use std::path::PathBuf;

pub struct NodeModeState {
    node_env_path: PathBuf,
    state_dir: PathBuf,
}

impl NodeModeState {
    /// Resolve node.env and state directory paths.
    pub fn new(state_dir: Option<PathBuf>) -> Result<Self> {
        let state_dir = state_dir
            .or_else(|| std::env::var("CHUMP_STATE_DIR").ok().map(PathBuf::from))
            .or_else(|| {
                let home = std::env::var("HOME").ok()?;
                Some(PathBuf::from(home).join(".chump"))
            })
            .context("unable to resolve state directory; set CHUMP_STATE_DIR or HOME")?;

        let node_env_path = crate::node_pause::node_env_path(&state_dir);
        Ok(NodeModeState {
            node_env_path,
            state_dir,
        })
    }

    /// Pause the node: set CHUMP_NODE_MODE=paused in node.env, write the node
    /// pause sentinel, and emit the pause event.
    ///
    /// RESILIENT-1652/1653: the durable operator-pause signal is `node.env`
    /// `CHUMP_NODE_MODE=paused` PLUS the node pause sentinel
    /// `<state_dir>/.chump/fleet-paused` (carrying `REASON=…`), written through
    /// the ONE shared [`crate::node_pause::node_sentinel_path`] every reader
    /// uses — node-converge's `_nc_paused`, the farmer gate, and
    /// `chump node is-paused`. This is a DIFFERENT file from the farmer kill
    /// switch `<repo>/.chump/fleet-paused` (owned by the ci-health-gate; a HARD
    /// RED the farmer gate never relaxes, RESILIENT-1636 RED2). Because the two
    /// live under distinct roots (state_dir ≠ repo), writing the node sentinel
    /// does NOT trip the kill switch, so a verb-paused node can still ship
    /// already-claimed work (re-entry admitted) — the cuphead ship-wall fix.
    pub fn pause(&self, reason: &str) -> Result<()> {
        // Read current node.env
        let mut contents = if self.node_env_path.exists() {
            fs::read_to_string(&self.node_env_path)?
        } else {
            String::new()
        };

        // Update CHUMP_NODE_MODE line
        self.update_or_add_line(&mut contents, "CHUMP_NODE_MODE", "paused");

        // Write updated node.env
        fs::write(&self.node_env_path, &contents).context("failed to write node.env")?;

        // Write the node pause sentinel (with reason + actor) through the ONE
        // shared path function — the same path node-converge / the farmer gate /
        // is-paused read (RESILIENT-1653 AC2: no reader checks a path no writer
        // writes). This is the node sentinel, NOT the repo kill switch.
        let actor = std::env::var("USER").unwrap_or_else(|_| "unknown".to_string());
        let sentinel_path = crate::node_pause::node_sentinel_path(&self.state_dir);
        let sentinel_content = format!(
            "REASON={}\nACTOR={}\nTIMESTAMP={}\n",
            reason,
            actor,
            Utc::now().format("%Y-%m-%dT%H:%M:%SZ")
        );
        if let Some(parent) = sentinel_path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&sentinel_path, sentinel_content)
            .context("failed to write node pause sentinel")?;

        // Emit node_paused event (carries the operator reason + actor).
        self.emit_ambient(
            "node_paused",
            &format!(
                r#""reason":"{}","actor":"{}""#,
                escape_json_string(reason),
                escape_json_string(&actor)
            ),
        )?;

        Ok(())
    }

    /// Resume the node: set CHUMP_NODE_MODE=work-ready in node.env, remove the
    /// node pause sentinel, and emit the resume event. RESILIENT-1652/1653:
    /// resume clears exactly the node sentinel `chump node pause` wrote
    /// (`<state_dir>/.chump/fleet-paused`), through the SAME shared path
    /// function — never the repo kill switch (that is the ci-health-gate's to
    /// clear on its own recovery).
    pub fn resume(&self) -> Result<()> {
        // Read current node.env
        let mut contents = if self.node_env_path.exists() {
            fs::read_to_string(&self.node_env_path)?
        } else {
            String::new()
        };

        // Update CHUMP_NODE_MODE line
        self.update_or_add_line(&mut contents, "CHUMP_NODE_MODE", "work-ready");

        // Write updated node.env
        fs::write(&self.node_env_path, &contents).context("failed to write node.env")?;

        // Remove the node pause sentinel (OK if it doesn't exist).
        let sentinel_path = crate::node_pause::node_sentinel_path(&self.state_dir);
        let _ = fs::remove_file(&sentinel_path);

        // Emit node_resumed event
        self.emit_ambient("node_resumed", "")?;

        Ok(())
    }

    /// Check if the node is currently paused — the pause DETECTOR half of the
    /// ONE predicate shared with the farmer gate (RESILIENT-1652). Reads the
    /// node state dir: `node.env` (both line forms + the legacy control-plane
    /// form) and the `<state_dir>/.chump/fleet-paused` node pause sentinel.
    pub fn is_paused(&self) -> Result<bool> {
        Ok(crate::node_pause::is_paused(&self.state_dir))
    }

    /// Update or add a line in node.env. INFRA-8588: node.env must be the single
    /// systemd-compatible form (bare `KEY=VALUE`, no `export` — systemd's
    /// EnvironmentFile parser rejects `export` lines), so we match an EXISTING
    /// line in either form (to migrate a pre-INFRA-8588 file in place) but always
    /// write the bare form via chump_provision::node_env::render_line.
    fn update_or_add_line(&self, contents: &mut String, key: &str, value: &str) {
        let bare_prefix = format!("{}=", key);
        let export_prefix = format!("export {}=", key);
        let is_match = |line: &str| {
            let t = line.trim_start();
            t.starts_with(&bare_prefix) || t.starts_with(&export_prefix)
        };
        let new_line = chump_provision::node_env::render_line(key, value);

        if contents.lines().any(is_match) {
            // Replace existing line (migrates `export KEY=` → bare `KEY=`).
            *contents = contents
                .lines()
                .map(|line| {
                    if is_match(line) {
                        new_line.clone()
                    } else {
                        line.to_string()
                    }
                })
                .collect::<Vec<_>>()
                .join("\n");
            if !contents.ends_with('\n') {
                contents.push('\n');
            }
        } else {
            // Add new line
            if !contents.ends_with('\n') && !contents.is_empty() {
                contents.push('\n');
            }
            contents.push_str(&new_line);
            contents.push('\n');
        }
    }

    /// Emit an ambient event.
    fn emit_ambient(&self, kind: &str, extra: &str) -> Result<()> {
        let ambient_path = self.state_dir.join("ambient.jsonl");

        let ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
        let event = if extra.is_empty() {
            format!(r#"{{"ts":"{}","kind":"{}"}}"#, ts, kind)
        } else {
            format!(r#"{{"ts":"{}","kind":"{}",{}}}"#, ts, kind, extra)
        };

        // Try to create the ambient file if it doesn't exist, but don't fail if we can't
        if let Some(parent) = ambient_path.parent() {
            let _ = fs::create_dir_all(parent);
        }

        match fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&ambient_path)
        {
            Ok(mut file) => {
                use std::io::Write;
                let _ = writeln!(file, "{}", event);
            }
            Err(_) => {
                // Ambient emit is best-effort; don't fail if we can't write it
            }
        }

        Ok(())
    }
}

/// Escape special characters in JSON strings.
fn escape_json_string(s: &str) -> String {
    s.chars()
        .flat_map(|c| match c {
            '"' => vec!['\\', '"'],
            '\\' => vec!['\\', '\\'],
            '\n' => vec!['\\', 'n'],
            '\r' => vec!['\\', 'r'],
            '\t' => vec!['\\', 't'],
            c => vec![c],
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    /// Build a state rooted at the temp dir, so the pause verb writes + the
    /// detector reads node.env + the node pause sentinel there.
    fn state_at(path: &std::path::Path) -> NodeModeState {
        NodeModeState {
            node_env_path: crate::node_pause::node_env_path(path),
            state_dir: path.to_path_buf(),
        }
    }

    #[test]
    fn test_pause_resume_cycle() -> Result<()> {
        let temp_dir = TempDir::new()?;
        let state_path = temp_dir.path();

        fs::create_dir_all(state_path.join(".chump"))?;

        let state = state_at(state_path);

        // Initially not paused
        assert!(!state.is_paused()?);

        // Pause the node
        state.pause("test pause reason")?;
        assert!(state.is_paused()?);

        // Verify node.env was updated — INFRA-8588: bare, no `export`.
        let contents = fs::read_to_string(state_path.join("node.env"))?;
        assert!(contents.contains("CHUMP_NODE_MODE=paused"));
        assert!(
            chump_provision::node_env::export_violations(&contents).is_empty(),
            "pause must not write an export line: {contents:?}"
        );

        // RESILIENT-1652/1653: pause writes the NODE pause sentinel at exactly
        // `<state_dir>/.chump/fleet-paused` (the shared path node-converge reads)
        // carrying REASON=, and NEVER the doubled `.chump/.chump` path.
        let sentinel = crate::node_pause::node_sentinel_path(state_path);
        assert_eq!(sentinel, state_path.join(".chump").join("fleet-paused"));
        assert!(
            sentinel.exists(),
            "pause must write the node pause sentinel"
        );
        assert!(
            fs::read_to_string(&sentinel)?.contains("REASON=test pause reason"),
            "node pause sentinel must carry the reason"
        );
        assert!(!state_path
            .join(".chump")
            .join(".chump")
            .join("fleet-paused")
            .exists());

        // Resume the node
        state.resume()?;
        assert!(!state.is_paused()?);

        // Verify node.env was updated — INFRA-8588: bare, no `export`.
        let contents = fs::read_to_string(state_path.join("node.env"))?;
        assert!(contents.contains("CHUMP_NODE_MODE=work-ready"));
        assert!(
            chump_provision::node_env::export_violations(&contents).is_empty(),
            "resume must not write an export line: {contents:?}"
        );

        // Resume removes the node pause sentinel it wrote.
        assert!(
            !sentinel.exists(),
            "resume must remove the node pause sentinel"
        );

        Ok(())
    }

    #[test]
    fn pause_detector_recognises_legacy_control_plane_form() -> Result<()> {
        // RESILIENT-1652: the cuphead pause form (control-plane + WORK_ENABLED=0,
        // set before the pause verb existed) must read as paused.
        let temp_dir = TempDir::new()?;
        let state_path = temp_dir.path();
        fs::create_dir_all(state_path.join(".chump"))?;
        fs::write(
            state_path.join("node.env"),
            "export CHUMP_NODE_MODE=control-plane\nexport CHUMP_NODE_WORK_ENABLED=0\n",
        )?;
        let state = state_at(state_path);
        assert!(state.is_paused()?);
        Ok(())
    }

    #[test]
    fn pause_detector_reads_node_sentinel() -> Result<()> {
        // RESILIENT-1653 AC2: the detector reads the NODE pause sentinel
        // `<state_dir>/.chump/fleet-paused` — the same path `chump node pause`
        // writes and node-converge's `_nc_paused` reads.
        let temp_dir = TempDir::new()?;
        let state_path = temp_dir.path();
        fs::create_dir_all(state_path.join(".chump"))?;
        fs::write(state_path.join("node.env"), "CHUMP_NODE_MODE=work-ready\n")?;
        let state = state_at(state_path);
        assert!(!state.is_paused()?);
        fs::write(
            crate::node_pause::node_sentinel_path(state_path),
            "REASON=slo_breach\n",
        )?;
        assert!(state.is_paused()?);
        Ok(())
    }

    #[test]
    fn pause_preserves_existing_line_forms_of_other_keys() -> Result<()> {
        // RESILIENT-1653 AC3 / task (4): writing node.env preserves each OTHER
        // existing line verbatim (bare stays bare, export stays export); only
        // the CHUMP_NODE_MODE line is normalised to the single documented
        // systemd-compatible bare form (INFRA-8588).
        let temp_dir = TempDir::new()?;
        let state_path = temp_dir.path();
        fs::create_dir_all(state_path.join(".chump"))?;
        fs::write(
            state_path.join("node.env"),
            "export CHUMP_STATE_DIR=/home/ubuntu/.chump\n\
             CHUMP_MAX_CONCURRENT_CARGO_JOBS=2\n\
             export CHUMP_RUN_USER=ubuntu\n\
             export CHUMP_NODE_MODE=work-ready\n",
        )?;
        let state = state_at(state_path);
        state.pause("maintenance")?;
        let contents = fs::read_to_string(state_path.join("node.env"))?;
        // Other lines kept verbatim — bare stays bare, export stays export.
        assert!(
            contents.contains("export CHUMP_STATE_DIR=/home/ubuntu/.chump"),
            "bare/export form of other keys must be preserved: {contents:?}"
        );
        assert!(contents.contains("\nCHUMP_MAX_CONCURRENT_CARGO_JOBS=2"));
        assert!(contents.contains("export CHUMP_RUN_USER=ubuntu"));
        // The written key is the single documented bare form.
        assert!(contents.contains("CHUMP_NODE_MODE=paused"));
        assert!(!contents.contains("export CHUMP_NODE_MODE="));
        Ok(())
    }
}
