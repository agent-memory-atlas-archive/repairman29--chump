//! Worker capability adapter (INFRA-2002 / META-107 sub-gap #6).
//!
//! `WorkerCapability` is the runtime view of "what this worker process can
//! pick" — distinct from [`crate::capability::CapabilityManifest`] which is
//! the wire-format published into NATS KV for cross-fleet visibility
//! (INFRA-1760, chump-capability-v1 schema).
//!
//! ## Why a separate struct
//!
//! The wire manifest has TTL / hardware / serde semantics tuned for KV
//! storage; the per-cycle pickability question is much smaller — "given
//! `gap.skills_required`, `gap.preferred_machine`, `gap.preferred_backend`,
//! does this worker match?". Keeping it small means the loop body never
//! needs to deserialize a full manifest just to filter the next gap.
//!
//! ## Phase 1 scope
//!
//! - Build `WorkerCapability` from env (`WORKER_SKILLS`, `WORKER_MACHINE`,
//!   `WORKER_BACKEND`).
//! - Provide `matches(&GapRow)` for picker filtering.
//! - Provide `to_manifest()` adapter for future KV publish (deferred per the
//!   Phase 1 non-goals list in the gap description).
//!
//! Phase 2 (NOT in this PR): publish the manifest to the
//! `chump_capabilities` KV bucket, heartbeat refresh, presence query API.

use crate::capability::{CapabilityManifest, CAPABILITY_SCHEMA_VERSION, DEFAULT_TTL_SECONDS};
use chrono::Utc;
use chump_gap_store::GapRow;
use serde::{Deserialize, Serialize};
use std::env;

/// Prefix used in `skills_required` to tag a gap as external-repo demo work.
///
/// Format: `external_repo:<owner>/<repo>` (e.g. `external_repo:ehippy/derelict`)
/// or bare `external_repo`.
/// When present the picker skips the gap unless `WorkerCapability::external_repo_enabled`
/// is `true` (`CHUMP_EXTERNAL_REPO_PICK_OK=1` or `true`).
/// Picked gaps are routed through `ExternalRepoContract` (INFRA-2111) instead
/// of the standard internal worker path.
pub const EXTERNAL_REPO_SKILL_PREFIX: &str = "external_repo:";
pub const EXTERNAL_REPO_SKILL_TAG: &str = "external_repo";

fn is_external_repo_skill(s: &str) -> bool {
    let t = s.trim();
    t == EXTERNAL_REPO_SKILL_TAG || t.starts_with(EXTERNAL_REPO_SKILL_PREFIX)
}

/// Returns `true` if any entry in `skills_required` equals [`EXTERNAL_REPO_SKILL_TAG`]
/// or starts with [`EXTERNAL_REPO_SKILL_PREFIX`], indicating this gap targets an
/// external repository rather than the Chump codebase itself.
pub fn has_external_repo_tag(gap: &GapRow) -> bool {
    gap.skills_required.split(',').any(is_external_repo_skill)
}

/// Parse `CHUMP_EXTERNAL_REPO_PICK_OK` from environment (`"1"` or `"true"` -> `true`,
/// everything else -> `false`).
pub fn external_repo_pick_ok_from_env() -> bool {
    env::var("CHUMP_EXTERNAL_REPO_PICK_OK")
        .ok()
        .map(|v| {
            let trimmed = v.trim();
            trimmed == "1" || trimmed.eq_ignore_ascii_case("true")
        })
        .unwrap_or(false)
}

/// Extract the `owner/repo` portion from the first `external_repo:<owner>/<repo>`
/// tag found in `skills_required`. Returns `None` if no such tag is present or
/// if the repo portion is empty.
pub fn extract_external_repo(gap: &GapRow) -> Option<String> {
    gap.skills_required.split(',').find_map(|s| {
        let trimmed = s.trim();
        trimmed
            .strip_prefix(EXTERNAL_REPO_SKILL_PREFIX)
            .filter(|repo| !repo.is_empty())
            .map(|repo| repo.to_string())
    })
}

/// Tag used in `skills_required` to mark a gap as workspace-scoped (RESILIENT-292):
/// its acceptance criteria require reading/writing files one level above the
/// claiming repo (sibling dirs under `~/Projects/`, e.g. `~/Projects/.claude/`,
/// `~/Projects/posse/`). A fleet-worker's linked worktree has no filesystem path
/// to those dirs, so this tag routes the gap to an operator/ATC session instead
/// of the standard pull-loop worker.
///
/// When present the picker skips the gap unless `CHUMP_WORKSPACE_SCOPE_PICK_OK=1`
/// (set by operator/ATC sessions that run with real `~/Projects` access, i.e.
/// NOT a fleet-worker linked worktree).
pub const WORKSPACE_SCOPE_SKILL_TAG: &str = "workspace_scope";

/// Returns `true` if any entry in `skills_required` equals
/// [`WORKSPACE_SCOPE_SKILL_TAG`], indicating this gap requires filesystem
/// access outside the claiming repo's own tree.
pub fn has_workspace_scope_tag(gap: &GapRow) -> bool {
    gap.skills_required
        .split(',')
        .any(|s| s.trim() == WORKSPACE_SCOPE_SKILL_TAG)
}

/// Per-worker capability view used by [`crate::worker::loop_body`].
///
/// Skills are matched against `gap.skills_required`; machine against
/// `gap.preferred_machine`; backend against `gap.preferred_backend`.
/// Empty / `"any"` values match unconditionally.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkerCapability {
    /// Free-form capability tags. Examples: "rust", "shell", "python".
    /// Sourced from `WORKER_SKILLS` (comma-separated). Empty = no skill filter.
    pub skills: Vec<String>,
    /// Machine identifier. Sourced from `WORKER_MACHINE`.
    /// `None` or `"any"` matches all `preferred_machine` values.
    pub machine: Option<String>,
    /// Backend identifier. Sourced from `WORKER_BACKEND`.
    /// `None` or `"any"` matches all `preferred_backend` values.
    pub backend: Option<String>,
    /// Session ID this capability is attached to (for manifest publish).
    pub session_id: String,
    /// INFRA-8602: First-class declared capability indicating whether this
    /// worker can pick external-repo gaps (`external_repo` or `external_repo:*`).
    /// Sourced from `CHUMP_EXTERNAL_REPO_PICK_OK` (`"1"` or `"true"` -> `true`,
    /// default `false`).
    #[serde(default)]
    pub external_repo_enabled: bool,
}

impl WorkerCapability {
    /// Build a `WorkerCapability` from environment variables.
    ///
    /// Falls back to "no filter" (empty skills, no machine, no backend) when
    /// env vars are absent — which matches the legacy `worker.sh` behavior of
    /// claiming any pickable gap, except `external_repo_enabled` defaults to
    /// `false` unless `CHUMP_EXTERNAL_REPO_PICK_OK` is `"1"` or `"true"`.
    pub fn from_env(session_id: impl Into<String>) -> Self {
        let skills = env::var("WORKER_SKILLS")
            .ok()
            .map(|s| {
                s.split(',')
                    .map(|t| t.trim().to_string())
                    .filter(|t| !t.is_empty())
                    .collect()
            })
            .unwrap_or_default();
        let machine = env::var("WORKER_MACHINE")
            .ok()
            .filter(|s| !s.is_empty() && s != "any");
        let backend = env::var("WORKER_BACKEND")
            .ok()
            .filter(|s| !s.is_empty() && s != "any");
        let external_repo_enabled = external_repo_pick_ok_from_env();
        Self {
            skills,
            machine,
            backend,
            session_id: session_id.into(),
            external_repo_enabled,
        }
    }

    /// Picker filter: does this worker match the gap's preferred routing?
    ///
    /// Match rules (all must hold):
    /// - If the gap is tagged `external_repo` or `external_repo:*`,
    ///   `self.external_repo_enabled` must be `true`.
    /// - If `gap.skills_required` is non-empty, at least one skill in
    ///   `self.skills` must appear in the gap's required list. If the
    ///   worker has no skills configured, the gap must also have no skill
    ///   requirement (conservative: don't claim a skill-tagged gap blindly).
    /// - If `gap.preferred_machine` is set, it must equal `self.machine`
    ///   (or be `"any"`).
    /// - If `gap.preferred_backend` is set, it must equal `self.backend`
    ///   (or be `"any"`).
    pub fn matches(&self, gap: &GapRow) -> bool {
        // External-repo gate (INFRA-2113 / INFRA-8602): gaps tagged `external_repo`
        // or `external_repo:<owner>/<repo>` are only pickable when this worker
        // declares `external_repo_enabled: true` (via `CHUMP_EXTERNAL_REPO_PICK_OK=1|true`).
        // Standard fleet workers skip them; the target curator opts-in explicitly.
        // When picked, the dispatch path must route through ExternalRepoContract (INFRA-2111).
        if has_external_repo_tag(gap) && !self.external_repo_enabled {
            return false;
        }

        // Workspace-scope gate (RESILIENT-292): gaps tagged `workspace_scope`
        // require filesystem access outside the claiming repo's own tree
        // (sibling dirs under `~/Projects/`). A standard fleet-worker's linked
        // worktree cannot reach those dirs, so these gaps are only pickable
        // when CHUMP_WORKSPACE_SCOPE_PICK_OK=1 — set by an operator/ATC session
        // that actually has real `~/Projects` access.
        if has_workspace_scope_tag(gap) {
            let pick_ok = env::var("CHUMP_WORKSPACE_SCOPE_PICK_OK")
                .map(|v| v.trim() == "1")
                .unwrap_or(false);
            if !pick_ok {
                return false;
            }
        }

        // Skills: parse comma-separated string from gap.
        let gap_skills: Vec<String> = gap
            .skills_required
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            // External-repo tags are routing hints, not skill requirements —
            // strip them before the standard skill-match logic so they do not
            // cause unrelated workers to be filtered out when the env gate is open.
            .filter(|s| !is_external_repo_skill(s))
            // Workspace-scope tag is likewise a routing hint, not a skill
            // requirement — strip it so it doesn't filter out ATC/operator
            // workers that opted in via the env gate above but have no
            // matching WORKER_SKILLS entry.
            .filter(|s| s != WORKSPACE_SCOPE_SKILL_TAG)
            .collect();
        if !gap_skills.is_empty() {
            if self.skills.is_empty() {
                return false;
            }
            let has_match = gap_skills.iter().any(|gs| self.skills.contains(gs));
            if !has_match {
                return false;
            }
        }

        // Machine: gap.preferred_machine must match self.machine (or "any" / empty).
        let pm = gap.preferred_machine.trim();
        if !pm.is_empty() && pm != "any" {
            match self.machine.as_deref() {
                Some(m) if m == pm => {}
                _ => return false,
            }
        }

        // Backend: gap.preferred_backend must match self.backend (or "any" / empty).
        let pb = gap.preferred_backend.trim();
        if !pb.is_empty() && pb != "any" {
            match self.backend.as_deref() {
                Some(b) if b == pb => {}
                _ => return false,
            }
        }

        true
    }

    /// Build a `CapabilityManifest` wire-format view of this capability.
    /// Used by the (deferred) KV publish path; included here so callers
    /// have one struct to thread through the worker loop.
    pub fn to_manifest(&self) -> CapabilityManifest {
        let now = Utc::now();
        CapabilityManifest {
            schema_version: CAPABILITY_SCHEMA_VERSION.to_string(),
            session_id: self.session_id.clone(),
            harness: env::var("CHUMP_AGENT_HARNESS").unwrap_or_else(|_| "manual".to_string()),
            model_tier: env::var("FLEET_MODEL").unwrap_or_else(|_| "unknown".to_string()),
            skills: self.skills.clone(),
            machine: self.machine.clone(),
            gpu: None,
            ip: None,
            started_at: now,
            heartbeat_at: now,
            ttl_seconds: DEFAULT_TTL_SECONDS,
            external_repo_enabled: self.external_repo_enabled,
        }
    }
}

/// Resolve the path to `~/.chump/node.env` (or `$CHUMP_STATE_DIR/node.env`).
pub fn resolve_node_env_path() -> std::path::PathBuf {
    if let Ok(sd) = env::var("CHUMP_STATE_DIR") {
        let trimmed = sd.trim();
        if !trimmed.is_empty() {
            return std::path::PathBuf::from(trimmed).join("node.env");
        }
    }
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    std::path::PathBuf::from(home)
        .join(".chump")
        .join("node.env")
}

/// Read `CHUMP_EXTERNAL_REPO_PICK_OK` from `node.env` if present, falling back
/// to the process environment. Returns `(is_open, raw_val_or_unset)`.
pub fn read_external_repo_gate_state(node_env_path: &std::path::Path) -> (bool, String) {
    if let Ok(content) = std::fs::read_to_string(node_env_path) {
        let mut last_val: Option<String> = None;
        for line in content.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            let stripped = trimmed.strip_prefix("export ").unwrap_or(trimmed).trim();
            if let Some(rest) = stripped.strip_prefix("CHUMP_EXTERNAL_REPO_PICK_OK=") {
                let v = rest.trim().trim_matches('"').trim_matches('\'').to_string();
                last_val = Some(v);
            }
        }
        if let Some(v) = last_val {
            let open = v == "1" || v.eq_ignore_ascii_case("true");
            return (open, v);
        }
    }
    match env::var("CHUMP_EXTERNAL_REPO_PICK_OK") {
        Ok(v) => {
            let t = v.trim();
            let open = t == "1" || t.eq_ignore_ascii_case("true");
            (open, t.to_string())
        }
        Err(_) => (false, "0".to_string()),
    }
}

/// Write `CHUMP_EXTERNAL_REPO_PICK_OK=<val>` to `node.env` in plain `KEY=VALUE`
/// format (no `export ` prefix, per INFRA-8588 / INFRA-8604).
pub fn write_external_repo_gate_node_env(
    node_env_path: &std::path::Path,
    enabled: bool,
) -> std::io::Result<()> {
    if let Some(parent) = node_env_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let val = if enabled { "1" } else { "0" };
    let new_line = format!("CHUMP_EXTERNAL_REPO_PICK_OK={}", val);
    let existing = std::fs::read_to_string(node_env_path).unwrap_or_default();
    let mut out_lines: Vec<String> = Vec::new();
    let mut replaced = false;
    for line in existing.lines() {
        let trimmed = line.trim();
        let stripped = trimmed.strip_prefix("export ").unwrap_or(trimmed).trim();
        if stripped.starts_with("CHUMP_EXTERNAL_REPO_PICK_OK=") {
            if !replaced {
                out_lines.push(new_line.clone());
                replaced = true;
            }
        } else {
            out_lines.push(line.to_string());
        }
    }
    if !replaced {
        out_lines.push(new_line);
    }
    let mut body = out_lines.join("\n");
    body.push('\n');
    std::fs::write(node_env_path, body)
}

/// CLI handler for `chump fleet external-repo <status|enable|disable> [--json]` (INFRA-8604).
/// Returns `Ok(exit_code)`.
pub fn handle_fleet_external_repo(args: &[String], repo_root: &std::path::Path) -> i32 {
    let action = args.first().map(String::as_str).unwrap_or("help");
    let json_out = args.iter().any(|a| a == "--json");
    let node_env_path = resolve_node_env_path();

    match action {
        "enable" => {
            if let Err(e) = write_external_repo_gate_node_env(&node_env_path, true) {
                eprintln!(
                    "[fleet external-repo] failed to write {}: {}",
                    node_env_path.display(),
                    e
                );
                return 1;
            }
            println!(
                "external_repo gate: open (CHUMP_EXTERNAL_REPO_PICK_OK=1 in {})",
                node_env_path.display()
            );
            0
        }
        "disable" => {
            if let Err(e) = write_external_repo_gate_node_env(&node_env_path, false) {
                eprintln!(
                    "[fleet external-repo] failed to write {}: {}",
                    node_env_path.display(),
                    e
                );
                return 1;
            }
            println!(
                "external_repo gate: closed (CHUMP_EXTERNAL_REPO_PICK_OK=0 in {})",
                node_env_path.display()
            );
            0
        }
        "status" => {
            let (open, raw_val) = read_external_repo_gate_state(&node_env_path);
            let gate_str = if open { "open" } else { "closed" };
            let local_node = env::var("WORKER_MACHINE")
                .ok()
                .filter(|s| !s.is_empty())
                .or_else(crate::capability::hostname_or_label)
                .unwrap_or_else(|| "local".to_string());

            let mut node_states: Vec<(String, bool)> = vec![(local_node.clone(), open)];
            let cap_dir = repo_root.join(".chump-locks").join("capabilities");
            if let Ok(entries) = std::fs::read_dir(&cap_dir) {
                for entry in entries.flatten() {
                    let p = entry.path();
                    if p.extension().and_then(|s| s.to_str()) != Some("jsonl") {
                        continue;
                    }
                    if let Ok(content) = std::fs::read_to_string(&p) {
                        if let Some(last_line) =
                            content.lines().rev().find(|l| !l.trim().is_empty())
                        {
                            if let Ok(m) =
                                serde_json::from_str::<CapabilityManifest>(last_line.trim())
                            {
                                let label = m.machine.unwrap_or(m.session_id);
                                if !node_states.iter().any(|(n, _)| n == &label) {
                                    node_states.push((label, m.external_repo_enabled));
                                }
                            }
                        }
                    }
                }
            }

            if json_out {
                let nodes_json: Vec<serde_json::Value> = node_states
                    .iter()
                    .map(|(n, en)| {
                        serde_json::json!({
                            "node": n,
                            "external_repo_enabled": en,
                        })
                    })
                    .collect();
                let payload = serde_json::json!({
                    "external_repo_gate": gate_str,
                    "external_repo_enabled": open,
                    "chump_external_repo_pick_ok": raw_val,
                    "node_env": node_env_path.display().to_string(),
                    "nodes": nodes_json,
                });
                println!("{}", payload);
            } else {
                println!("external_repo gate: {}", gate_str);
                println!(
                    "node.env: {} (CHUMP_EXTERNAL_REPO_PICK_OK={})",
                    node_env_path.display(),
                    raw_val
                );
                println!("per-node external_repo capability:");
                for (node, en) in &node_states {
                    println!(
                        "  {}: external_repo_enabled={}",
                        node,
                        if *en { "true" } else { "false" }
                    );
                }
            }
            0
        }
        _ => {
            eprintln!("Usage: chump fleet external-repo <status|enable|disable> [--json]");
            2
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chump_gap_store::GapRow;
    use serial_test::serial;

    fn gap_with(skills: &str, machine: &str, backend: &str) -> GapRow {
        GapRow {
            id: "INFRA-TEST".to_string(),
            domain: "INFRA".to_string(),
            title: "test gap".to_string(),
            description: String::new(),
            priority: "P1".to_string(),
            effort: "s".to_string(),
            status: "open".to_string(),
            acceptance_criteria: "[]".to_string(),
            depends_on: String::new(),
            notes: String::new(),
            source_doc: String::new(),
            created_at: 0,
            closed_at: None,
            opened_date: String::new(),
            closed_date: String::new(),
            closed_pr: None,
            skills_required: skills.to_string(),
            preferred_backend: backend.to_string(),
            preferred_machine: machine.to_string(),
            estimated_minutes: String::new(),
            required_model: String::new(),
            shipped_in: None,
            outcome_id: None,
            evidence: None,
        }
    }

    #[test]
    fn empty_worker_matches_unconstrained_gap() {
        let w = WorkerCapability {
            skills: vec![],
            machine: None,
            backend: None,
            session_id: "s".to_string(),
            external_repo_enabled: false,
        };
        let g = gap_with("", "", "");
        assert!(w.matches(&g));
    }

    #[test]
    fn empty_worker_skips_skill_tagged_gap() {
        let w = WorkerCapability {
            skills: vec![],
            machine: None,
            backend: None,
            session_id: "s".to_string(),
            external_repo_enabled: false,
        };
        let g = gap_with("rust", "", "");
        assert!(
            !w.matches(&g),
            "no-skill worker must not claim skill-tagged gap"
        );
    }

    #[test]
    fn skill_match_required() {
        let w = WorkerCapability {
            skills: vec!["python".to_string()],
            machine: None,
            backend: None,
            session_id: "s".to_string(),
            external_repo_enabled: false,
        };
        let g = gap_with("rust", "", "");
        assert!(!w.matches(&g), "python worker must not match rust gap");
        let g2 = gap_with("rust,python", "", "");
        assert!(
            w.matches(&g2),
            "python worker matches multi-skill gap with python"
        );
    }

    #[test]
    fn machine_filter_respected() {
        let w = WorkerCapability {
            skills: vec![],
            machine: Some("macbook".to_string()),
            backend: None,
            session_id: "s".to_string(),
            external_repo_enabled: false,
        };
        let g = gap_with("", "rpi", "");
        assert!(!w.matches(&g));
        let g2 = gap_with("", "macbook", "");
        assert!(w.matches(&g2));
        let g3 = gap_with("", "any", "");
        assert!(w.matches(&g3));
    }

    #[test]
    #[serial]
    fn from_env_parses_comma_skills() {
        std::env::set_var("WORKER_SKILLS", "rust, shell , python");
        std::env::set_var("WORKER_MACHINE", "rpi");
        std::env::remove_var("WORKER_BACKEND");
        std::env::remove_var("CHUMP_EXTERNAL_REPO_PICK_OK");
        let w = WorkerCapability::from_env("s1");
        assert_eq!(
            w.skills,
            vec![
                "rust".to_string(),
                "shell".to_string(),
                "python".to_string()
            ]
        );
        assert_eq!(w.machine.as_deref(), Some("rpi"));
        assert_eq!(w.backend, None);
        assert!(!w.external_repo_enabled);
        std::env::remove_var("WORKER_SKILLS");
        std::env::remove_var("WORKER_MACHINE");
    }

    #[test]
    fn to_manifest_round_trip() {
        let w = WorkerCapability {
            skills: vec!["rust".to_string()],
            machine: Some("m".to_string()),
            backend: None,
            session_id: "sess-1".to_string(),
            external_repo_enabled: true,
        };
        let m = w.to_manifest();
        assert_eq!(m.schema_version, CAPABILITY_SCHEMA_VERSION);
        assert_eq!(m.session_id, "sess-1");
        assert_eq!(m.skills, vec!["rust".to_string()]);
        assert_eq!(m.machine.as_deref(), Some("m"));
        assert!(m.external_repo_enabled);
    }

    // ── external_repo tag tests (INFRA-2113 / INFRA-8602) ────────────────────
    // These tests mutate CHUMP_EXTERNAL_REPO_PICK_OK, so they must run serially
    // to avoid races with other tests that read the same env var.

    #[test]
    #[serial]
    fn external_repo_gap_skipped_by_default() {
        // Gap has external_repo tag; env var NOT set — must be skipped.
        std::env::remove_var("CHUMP_EXTERNAL_REPO_PICK_OK");
        let w = WorkerCapability::from_env("s");
        assert!(!w.external_repo_enabled);
        let g = gap_with("external_repo:ehippy/derelict", "", "");
        assert!(
            !w.matches(&g),
            "external-repo gap must be skipped when CHUMP_EXTERNAL_REPO_PICK_OK is unset"
        );
        let g_bare = gap_with("external_repo", "", "");
        assert!(
            !w.matches(&g_bare),
            "bare external_repo gap must be skipped when external_repo_enabled is false"
        );
    }

    #[test]
    #[serial]
    fn external_repo_gap_picked_when_opt_in() {
        // Gap has external_repo tag; env var IS set to 1 — must match.
        std::env::set_var("CHUMP_EXTERNAL_REPO_PICK_OK", "1");
        let w = WorkerCapability::from_env("s");
        assert!(w.external_repo_enabled);
        let g = gap_with("external_repo:ehippy/derelict", "", "");
        assert!(
            w.matches(&g),
            "external-repo gap must be picked when CHUMP_EXTERNAL_REPO_PICK_OK=1"
        );
        let g_bare = gap_with("external_repo", "", "");
        assert!(
            w.matches(&g_bare),
            "bare external_repo gap must be picked when external_repo_enabled is true"
        );
        std::env::remove_var("CHUMP_EXTERNAL_REPO_PICK_OK");
    }

    #[test]
    #[serial]
    fn from_env_accepts_true_and_rejects_false_or_zero() {
        std::env::set_var("CHUMP_EXTERNAL_REPO_PICK_OK", "true");
        let w_true = WorkerCapability::from_env("s");
        assert!(w_true.external_repo_enabled);
        assert!(w_true.to_manifest().external_repo_enabled);

        std::env::set_var("CHUMP_EXTERNAL_REPO_PICK_OK", "TRUE");
        assert!(WorkerCapability::from_env("s").external_repo_enabled);

        std::env::set_var("CHUMP_EXTERNAL_REPO_PICK_OK", "0");
        let w_zero = WorkerCapability::from_env("s");
        assert!(!w_zero.external_repo_enabled);
        assert!(!w_zero.to_manifest().external_repo_enabled);

        std::env::set_var("CHUMP_EXTERNAL_REPO_PICK_OK", "false");
        assert!(!WorkerCapability::from_env("s").external_repo_enabled);

        std::env::remove_var("CHUMP_EXTERNAL_REPO_PICK_OK");
    }

    #[test]
    #[serial]
    fn external_repo_tag_does_not_count_as_skill_requirement() {
        // A gap with ONLY an external_repo tag and the opt-in set must still
        // match a worker with no WORKER_SKILLS — the tag is a routing hint,
        // not a skill requirement.
        std::env::set_var("CHUMP_EXTERNAL_REPO_PICK_OK", "1");
        let w = WorkerCapability::from_env("s");
        let g = gap_with("external_repo:ehippy/derelict", "", "");
        assert!(
            w.matches(&g),
            "external_repo tag alone must not act as a skill filter"
        );
        std::env::remove_var("CHUMP_EXTERNAL_REPO_PICK_OK");
    }

    #[test]
    #[serial]
    fn external_repo_mixed_with_real_skill() {
        // Gap has both external_repo tag and a real skill requirement.
        // With opt-in set AND matching skill — should match.
        std::env::set_var("CHUMP_EXTERNAL_REPO_PICK_OK", "1");
        let w = WorkerCapability {
            skills: vec!["rust".to_string()],
            machine: None,
            backend: None,
            session_id: "s".to_string(),
            external_repo_enabled: true,
        };
        let g = gap_with("external_repo:ehippy/derelict,rust", "", "");
        assert!(
            w.matches(&g),
            "worker with matching skill should pick external-repo+rust gap"
        );

        // Without the matching skill — should not match.
        let w2 = WorkerCapability {
            skills: vec!["python".to_string()],
            machine: None,
            backend: None,
            session_id: "s".to_string(),
            external_repo_enabled: true,
        };
        assert!(
            !w2.matches(&g),
            "python worker must not match external-repo+rust gap"
        );
        std::env::remove_var("CHUMP_EXTERNAL_REPO_PICK_OK");
    }

    #[test]
    fn has_external_repo_tag_detects_prefix() {
        let g_yes = gap_with("external_repo:ehippy/derelict", "", "");
        let g_bare = gap_with("external_repo", "", "");
        let g_no = gap_with("rust,python", "", "");
        let g_empty = gap_with("", "", "");
        assert!(has_external_repo_tag(&g_yes));
        assert!(has_external_repo_tag(&g_bare));
        assert!(!has_external_repo_tag(&g_no));
        assert!(!has_external_repo_tag(&g_empty));
    }

    #[test]
    fn extract_external_repo_returns_owner_repo() {
        let g = gap_with("external_repo:ehippy/derelict", "", "");
        assert_eq!(
            extract_external_repo(&g).as_deref(),
            Some("ehippy/derelict")
        );
        let g2 = gap_with("rust", "", "");
        assert_eq!(extract_external_repo(&g2), None);
    }

    // ── workspace_scope tag tests (RESILIENT-292) ────────────────────────────
    // Mirrors the external_repo tests above. This is the "receipt" that a
    // previously-blocked workspace-scoped gap (e.g. CREDIBLE-234, which
    // released its claim 13 times because /root/Projects/ has no path to
    // sibling workspace dirs) becomes pickable once routed through the new
    // ATC/operator-only gate instead of the standard fleet pull loop.

    #[test]
    #[serial]
    fn workspace_scope_gap_skipped_by_default() {
        std::env::remove_var("CHUMP_WORKSPACE_SCOPE_PICK_OK");
        let w = WorkerCapability {
            skills: vec![],
            machine: None,
            backend: None,
            session_id: "s".to_string(),
            external_repo_enabled: false,
        };
        let g = gap_with("workspace_scope", "", "");
        assert!(
            !w.matches(&g),
            "workspace-scoped gap must be skipped by a standard fleet worker when \
             CHUMP_WORKSPACE_SCOPE_PICK_OK is unset"
        );
    }

    #[test]
    #[serial]
    fn workspace_scope_gap_picked_by_atc_session() {
        // Simulates an operator/ATC session (real ~/Projects access) opting in.
        std::env::set_var("CHUMP_WORKSPACE_SCOPE_PICK_OK", "1");
        let w = WorkerCapability {
            skills: vec![],
            machine: None,
            backend: None,
            session_id: "atc".to_string(),
            external_repo_enabled: false,
        };
        let g = gap_with("workspace_scope", "", "");
        assert!(
            w.matches(&g),
            "previously-blocked workspace-scoped gap must be pickable by an \
             ATC/operator session with CHUMP_WORKSPACE_SCOPE_PICK_OK=1"
        );
        std::env::remove_var("CHUMP_WORKSPACE_SCOPE_PICK_OK");
    }

    #[test]
    #[serial]
    fn workspace_scope_tag_does_not_count_as_skill_requirement() {
        std::env::set_var("CHUMP_WORKSPACE_SCOPE_PICK_OK", "1");
        let w = WorkerCapability {
            skills: vec![],
            machine: None,
            backend: None,
            session_id: "s".to_string(),
            external_repo_enabled: false,
        };
        let g = gap_with("workspace_scope", "", "");
        assert!(
            w.matches(&g),
            "workspace_scope tag alone must not act as a skill filter"
        );
        std::env::remove_var("CHUMP_WORKSPACE_SCOPE_PICK_OK");
    }

    #[test]
    fn has_workspace_scope_tag_detects_tag() {
        let g_yes = gap_with("workspace_scope", "", "");
        let g_mixed = gap_with("rust,workspace_scope", "", "");
        let g_no = gap_with("rust,python", "", "");
        let g_empty = gap_with("", "", "");
        assert!(has_workspace_scope_tag(&g_yes));
        assert!(has_workspace_scope_tag(&g_mixed));
        assert!(!has_workspace_scope_tag(&g_no));
        assert!(!has_workspace_scope_tag(&g_empty));
    }
}
