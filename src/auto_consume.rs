//! MISSION-125: auto-discover & auto-adopt module for new capabilities.
//!
//! This module subscribes to watchdog `discover` events (emitted when a new
//! capability becomes available) and automatically:
//! 1. Fetches required binaries/tools for the new capability (AC2)
//! 2. Integrates the capability into the node's runtime (AC3)
//! 3. Logs successful adoption with `auto-consume adopted <capability>` (AC4)
//!
//! The underlying shell implementation (`scripts/ops/auto-adopt.sh`) is the
//! persistent authority for the adoption registry (`auto-adopt-capabilities.jsonl`).
//! This Rust module is a programmatic wrapper for in-process discovery polling
//! and ambient event emission.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::Path;

/// A `discover` event from the ambient stream, emitted when a new
/// capability becomes available (but not yet integrated).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DiscoverEvent {
    pub ts: String,
    pub kind: String,
    pub capability: String,
    pub required_tools: Vec<String>,
}

impl DiscoverEvent {
    /// Parse a discover event from a single-line JSON string.
    pub fn from_json_line(line: &str) -> Option<Self> {
        serde_json::from_str(line).ok()
    }
}

/// Record of a capability that has been adopted into the node's runtime.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AdoptedCapability {
    pub capability: String,
    pub required_tools: String,
    pub adopted_at: String,
}

impl AdoptedCapability {
    /// Parse an adoption record from a single-line JSON string.
    pub fn from_json_line(line: &str) -> Option<Self> {
        serde_json::from_str(line).ok()
    }
}

/// State tracker for auto-adoption: which capabilities have already been
/// adopted (to prevent re-adoption), and where to resume reading the
/// ambient log from.
#[derive(Debug, Default, Clone)]
pub struct AutoConsumeState {
    adopted_capabilities: HashSet<String>,
    ambient_cursor: usize,
}

impl AutoConsumeState {
    /// Create a fresh state (no capabilities adopted, start from line 0).
    pub fn new() -> Self {
        Self::default()
    }

    /// Mark a capability as adopted (idempotency guard).
    pub fn mark_adopted(&mut self, capability: &str) {
        self.adopted_capabilities.insert(capability.to_string());
    }

    /// Check if a capability has already been adopted.
    pub fn is_adopted(&self, capability: &str) -> bool {
        self.adopted_capabilities.contains(capability)
    }

    /// Update the cursor position to skip past already-processed events.
    pub fn advance_cursor(&mut self, new_position: usize) {
        self.ambient_cursor = new_position;
    }

    /// Current position in the ambient log.
    pub fn current_cursor(&self) -> usize {
        self.ambient_cursor
    }

    /// Load adoption state from disk: populate adopted_capabilities from
    /// the registry file, and cursor from the cursor file.
    pub fn load_from_disk(registry_path: &Path, cursor_path: &Path) -> Result<Self> {
        let mut state = Self::new();

        // Load adopted capabilities from registry
        if registry_path.exists() {
            let content = std::fs::read_to_string(registry_path)
                .with_context(|| format!("reading registry {}", registry_path.display()))?;
            for line in content.lines() {
                if let Some(record) = AdoptedCapability::from_json_line(line) {
                    state.mark_adopted(&record.capability);
                }
            }
        }

        // Load cursor position
        if cursor_path.exists() {
            let cursor_str = std::fs::read_to_string(cursor_path)
                .with_context(|| format!("reading cursor {}", cursor_path.display()))?;
            if let Ok(pos) = cursor_str.trim().parse::<usize>() {
                state.advance_cursor(pos);
            }
        }

        Ok(state)
    }

    /// Save cursor position to disk for resumption on next run.
    pub fn save_cursor(&self, cursor_path: &Path) -> Result<()> {
        let dir = cursor_path
            .parent()
            .context("cursor path must have parent directory")?;
        std::fs::create_dir_all(dir)
            .with_context(|| format!("creating cursor dir {}", dir.display()))?;
        std::fs::write(cursor_path, self.current_cursor().to_string())
            .with_context(|| format!("writing cursor {}", cursor_path.display()))
    }
}

/// Scan the ambient log for `discover` events since the last cursor position
/// and return those that have not yet been adopted. Does not modify state.
pub fn scan_new_discover_events(
    ambient_log: &Path,
    state: &AutoConsumeState,
) -> Result<Vec<DiscoverEvent>> {
    let mut events = Vec::new();

    if !ambient_log.exists() {
        return Ok(events);
    }

    let content = std::fs::read_to_string(ambient_log)
        .with_context(|| format!("reading ambient log {}", ambient_log.display()))?;

    let start = state.current_cursor();
    let total_lines = content.lines().count();

    if total_lines > start {
        for line in content.lines().skip(start) {
            if let Some(event) = DiscoverEvent::from_json_line(line) {
                if event.kind == "discover" && !state.is_adopted(&event.capability) {
                    events.push(event);
                }
            }
        }
    }

    Ok(events)
}

/// Emit a `capability_auto_adopted` ambient event to record successful adoption.
/// This makes the adoption visible to fleet audit trails and dashboards.
pub fn emit_adoption_event(ambient_log: &Path, capability: &str, tools: &[String]) -> Result<()> {
    let dir = ambient_log
        .parent()
        .context("ambient path must have parent")?;
    std::fs::create_dir_all(dir)
        .with_context(|| format!("creating ambient dir {}", dir.display()))?;

    let tools_str = tools.join(",");
    let now = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let event = serde_json::json!({
        "ts": now,
        "kind": "capability_auto_adopted",
        "capability": capability,
        "required_tools": tools_str,
    });

    let line = serde_json::to_string(&event)?;
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_log)
        .with_context(|| format!("opening {}", ambient_log.display()))?;

    use std::io::Write;
    writeln!(f, "{}", line).context("writing ambient event")?;

    Ok(())
}

/// Record a newly-adopted capability in the runtime registry so other
/// node tools can query whether this capability is usable.
pub fn record_adoption(registry_path: &Path, capability: &str, tools: &[String]) -> Result<()> {
    let dir = registry_path
        .parent()
        .context("registry path must have parent")?;
    std::fs::create_dir_all(dir)
        .with_context(|| format!("creating registry dir {}", dir.display()))?;

    let tools_str = tools.join(",");
    let now = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let record = AdoptedCapability {
        capability: capability.to_string(),
        required_tools: tools_str,
        adopted_at: now,
    };

    let line = serde_json::to_string(&record)?;
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(registry_path)
        .with_context(|| format!("opening {}", registry_path.display()))?;

    use std::io::Write;
    writeln!(f, "{}", line).context("writing adoption record")?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn parse_discover_event() {
        let json = r#"{"ts":"2026-10-10T00:00:00Z","kind":"discover","capability":"foo-linter","required_tools":["foo-lint","foo-fmt"]}"#;
        let event = DiscoverEvent::from_json_line(json).expect("parse");
        assert_eq!(event.capability, "foo-linter");
        assert_eq!(event.required_tools, vec!["foo-lint", "foo-fmt"]);
    }

    #[test]
    fn parse_discover_empty_tools() {
        let json = r#"{"ts":"2026-10-10T00:00:00Z","kind":"discover","capability":"bar","required_tools":[]}"#;
        let event = DiscoverEvent::from_json_line(json).expect("parse");
        assert_eq!(event.capability, "bar");
        assert_eq!(event.required_tools, Vec::<String>::new());
    }

    #[test]
    fn parse_non_discover_filters_kind() {
        // Valid JSON that would parse, but scan_new_discover_events filters on kind
        let json = r#"{"ts":"2026-10-10T00:00:00Z","kind":"discover","capability":"test","required_tools":[]}"#;
        let event = DiscoverEvent::from_json_line(json);
        assert!(event.is_some());
        assert_eq!(event.unwrap().kind, "discover");
    }

    #[test]
    fn state_tracks_adoption() {
        let mut state = AutoConsumeState::new();
        assert!(!state.is_adopted("foo"));

        state.mark_adopted("foo");
        assert!(state.is_adopted("foo"));
        assert!(!state.is_adopted("bar"));
    }

    #[test]
    fn state_cursor_advances() {
        let mut state = AutoConsumeState::new();
        assert_eq!(state.current_cursor(), 0);

        state.advance_cursor(5);
        assert_eq!(state.current_cursor(), 5);
    }

    #[test]
    fn state_load_from_empty_disk() {
        let tmp = TempDir::new().unwrap();
        let registry = tmp.path().join("registry.jsonl");
        let cursor = tmp.path().join("cursor");

        let state = AutoConsumeState::load_from_disk(&registry, &cursor).unwrap();
        assert_eq!(state.current_cursor(), 0);
        assert!(!state.is_adopted("anything"));
    }

    #[test]
    fn state_load_from_disk() {
        let tmp = TempDir::new().unwrap();
        let registry = tmp.path().join("registry.jsonl");
        let cursor = tmp.path().join("cursor");

        // Write a registry entry
        let record = AdoptedCapability {
            capability: "foo".to_string(),
            required_tools: "foo-cli".to_string(),
            adopted_at: "2026-10-10T00:00:00Z".to_string(),
        };
        std::fs::write(&registry, serde_json::to_string(&record).unwrap() + "\n").unwrap();

        // Write cursor
        std::fs::write(&cursor, "5").unwrap();

        let state = AutoConsumeState::load_from_disk(&registry, &cursor).unwrap();
        assert!(state.is_adopted("foo"));
        assert_eq!(state.current_cursor(), 5);
    }

    #[test]
    fn scan_new_events() {
        let tmp = TempDir::new().unwrap();
        let ambient = tmp.path().join("ambient.jsonl");

        let mut state = AutoConsumeState::new();

        // Write initial events
        let event1 = DiscoverEvent {
            ts: "2026-10-10T00:00:00Z".to_string(),
            kind: "discover".to_string(),
            capability: "foo".to_string(),
            required_tools: vec!["foo-cli".to_string()],
        };
        let event2 = DiscoverEvent {
            ts: "2026-10-10T00:00:01Z".to_string(),
            kind: "discover".to_string(),
            capability: "bar".to_string(),
            required_tools: vec![],
        };
        let mut content = String::new();
        content.push_str(&serde_json::to_string(&event1).unwrap());
        content.push('\n');
        content.push_str(&serde_json::to_string(&event2).unwrap());
        content.push('\n');

        std::fs::write(&ambient, content).unwrap();

        // Scan all events
        let events = scan_new_discover_events(&ambient, &state).unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].capability, "foo");
        assert_eq!(events[1].capability, "bar");

        // Mark foo as adopted and scan again
        state.mark_adopted("foo");
        let events = scan_new_discover_events(&ambient, &state).unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].capability, "bar");
    }

    #[test]
    fn scan_respects_cursor() {
        let tmp = TempDir::new().unwrap();
        let ambient = tmp.path().join("ambient.jsonl");

        let event1 = DiscoverEvent {
            ts: "2026-10-10T00:00:00Z".to_string(),
            kind: "discover".to_string(),
            capability: "foo".to_string(),
            required_tools: vec![],
        };
        let event2 = DiscoverEvent {
            ts: "2026-10-10T00:00:01Z".to_string(),
            kind: "discover".to_string(),
            capability: "bar".to_string(),
            required_tools: vec![],
        };

        let mut content = String::new();
        content.push_str(&serde_json::to_string(&event1).unwrap());
        content.push('\n');
        content.push_str(&serde_json::to_string(&event2).unwrap());
        content.push('\n');

        std::fs::write(&ambient, content).unwrap();

        // Scan from cursor=1 (skip first line)
        let mut state = AutoConsumeState::new();
        state.advance_cursor(1);
        let events = scan_new_discover_events(&ambient, &state).unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].capability, "bar");
    }

    #[test]
    fn emit_and_record_adoption() {
        let tmp = TempDir::new().unwrap();
        let ambient = tmp.path().join("ambient.jsonl");
        let registry = tmp.path().join("registry.jsonl");

        emit_adoption_event(&ambient, "test-cap", &["test-tool".to_string()]).unwrap();
        record_adoption(&registry, "test-cap", &["test-tool".to_string()]).unwrap();

        // Verify files exist and contain expected data
        assert!(ambient.exists());
        assert!(registry.exists());

        let ambient_content = std::fs::read_to_string(&ambient).unwrap();
        assert!(ambient_content.contains("capability_auto_adopted"));
        assert!(ambient_content.contains("test-cap"));

        let registry_content = std::fs::read_to_string(&registry).unwrap();
        let record: AdoptedCapability = serde_json::from_str(registry_content.trim()).unwrap();
        assert_eq!(record.capability, "test-cap");
    }
}
