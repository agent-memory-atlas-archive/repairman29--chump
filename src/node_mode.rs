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

        let node_env_path = state_dir.join("node.env");
        Ok(NodeModeState {
            node_env_path,
            state_dir,
        })
    }

    /// Pause the node: set CHUMP_NODE_MODE=paused in node.env and emit the pause event.
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

        // Write the paused sentinel with reason and actor
        let actor = std::env::var("USER").unwrap_or_else(|_| "unknown".to_string());
        let sentinel_path = self.state_dir.join(".chump").join("fleet-paused");
        let sentinel_content = format!(
            "REASON={}\nACTOR={}\nTIMESTAMP={}\n",
            reason,
            actor,
            Utc::now().format("%Y-%m-%dT%H:%M:%SZ")
        );
        fs::create_dir_all(sentinel_path.parent().unwrap())?;
        fs::write(&sentinel_path, sentinel_content)
            .context("failed to write fleet-paused sentinel")?;

        // Emit node_paused event
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

    /// Resume the node: set CHUMP_NODE_MODE=work-ready in node.env and emit the resume event.
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

        // Remove the paused sentinel
        let sentinel_path = self.state_dir.join(".chump").join("fleet-paused");
        let _ = fs::remove_file(&sentinel_path); // OK if it doesn't exist

        // Emit node_resumed event
        self.emit_ambient("node_resumed", "")?;

        Ok(())
    }

    /// Check if the node is currently paused.
    pub fn is_paused(&self) -> Result<bool> {
        if !self.node_env_path.exists() {
            return Ok(false);
        }

        let contents = fs::read_to_string(&self.node_env_path)?;
        Ok(contents
            .lines()
            .any(|line| line.trim().starts_with("export CHUMP_NODE_MODE=paused")))
    }

    /// Update or add a line in the node.env format.
    fn update_or_add_line(&self, contents: &mut String, key: &str, value: &str) {
        let prefix = format!("export {}=", key);
        let mut found = false;

        for line in contents.lines() {
            if line.trim().starts_with(&prefix) {
                found = true;
                break;
            }
        }

        if found {
            // Replace existing line
            let new_line = format!("export {}={}", key, value);
            *contents = contents
                .lines()
                .map(|line| {
                    if line.trim().starts_with(&prefix) {
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
            contents.push_str(&format!("export {}={}\n", key, value));
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

    #[test]
    fn test_pause_resume_cycle() -> Result<()> {
        let temp_dir = TempDir::new()?;
        let state_path = temp_dir.path();

        fs::create_dir_all(state_path.join(".chump"))?;

        let state = NodeModeState {
            node_env_path: state_path.join("node.env"),
            state_dir: state_path.to_path_buf(),
        };

        // Initially not paused
        assert!(!state.is_paused()?);

        // Pause the node
        state.pause("test pause reason")?;
        assert!(state.is_paused()?);

        // Verify node.env was updated
        let contents = fs::read_to_string(state_path.join("node.env"))?;
        assert!(contents.contains("export CHUMP_NODE_MODE=paused"));

        // Verify sentinel exists
        assert!(state_path.join(".chump").join("fleet-paused").exists());

        // Resume the node
        state.resume()?;
        assert!(!state.is_paused()?);

        // Verify node.env was updated
        let contents = fs::read_to_string(state_path.join("node.env"))?;
        assert!(contents.contains("export CHUMP_NODE_MODE=work-ready"));

        // Verify sentinel was removed
        assert!(!state_path.join(".chump").join("fleet-paused").exists());

        Ok(())
    }
}
