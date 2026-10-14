//! Maintenance tooling for the gap registry — INFRA-2000 (META-107 Phase 1).
//!
//! Ports four Python tools onto typed Rust on top of the existing
//! [`crate::GapStore`] surface so the canonical store has one parser stack
//! (Rust `serde_yaml`) instead of the Python `yaml.safe_load` + Rust
//! `serde_yaml` drift class that has bitten the fleet since INFRA-188.
//!
//! ## Modules
//!
//! - [`doctor`]   — drift detector + healer (gap-doctor.py)
//! - [`gardener`] — registry health audit + queue refill summary (gap-gardener.py)
//! - [`architect`] — LLM-driven decomposition (gap-architect.py) via the
//!                   [`architect::LlmClient`] trait
//! - [`integrity`] — YAML parse + duplicate-id + cross-check CI gate
//!                   (check-gaps-integrity.py)
//!
//! ## Phase 1 scope (per INFRA-2000 brief)
//!
//! - Module shape + invariants + CLI binaries that match the Python tools'
//!   argument surface.
//! - The four `.py` scripts gain a 5-line feature-flag shim:
//!   `CHUMP_GAP_MAINTENANCE_RUST=1` execs the Rust binary; otherwise the
//!   Python body runs. 1-week parallel-run discipline (matches INFRA-1999).
//! - No new ambient event kinds. The Python tools own ambient emit semantics
//!   in Phase 1; this module is read-or-report-only and never writes
//!   `.chump-locks/ambient.jsonl`.
//! - No registry-touching mutations beyond what the existing `GapStore`
//!   public API exposes.
//!
//! ## Non-goals (deferred to follow-up sub-gaps under META-107)
//!
//! - Decommissioning the Python tools. Both code paths live during a 1-week
//!   parallel-run window.
//! - Full LLM-call cost accounting inside [`architect`]. Phase 1 only
//!   surfaces stderr from the underlying `claude -p` binary so existing
//!   cost-collection paths keep working.
//! - Migrating callers of the `.py` scripts to call the Rust binaries
//!   directly. The shim transparently routes; callers see no API change.

pub mod architect;
pub mod doctor;
pub mod enricher;
pub mod gardener;
pub mod integrity;
pub mod migrator;

use std::path::{Path, PathBuf};

/// Resolve the repository root containing the canonical `.chump/state.db`.
///
/// Mirrors `gap-doctor.py::repo_root` — walks `git worktree list
/// --porcelain` and picks the first worktree entry (the main worktree).
/// Falls back to `git rev-parse --show-toplevel` when porcelain output
/// can't be parsed (e.g. test fixtures that aren't inside a git repo).
///
/// Returns the main worktree's path when its `.chump/state.db` exists and
/// is non-empty; otherwise the current worktree's root.
pub fn resolve_repo_root() -> std::io::Result<PathBuf> {
    let porcelain = std::process::Command::new("git")
        .args(["worktree", "list", "--porcelain"])
        .output()?;
    if porcelain.status.success() {
        let out = String::from_utf8_lossy(&porcelain.stdout);
        for line in out.lines() {
            if let Some(rest) = line.strip_prefix("worktree ") {
                let p = PathBuf::from(rest.trim());
                let db = p.join(".chump").join("state.db");
                if db.exists() && std::fs::metadata(&db).map(|m| m.len() > 0).unwrap_or(false) {
                    return Ok(p);
                }
                // First-listed worktree is the main one; if its DB is missing
                // we keep walking but most repos give us a hit here.
                break;
            }
        }
    }
    let toplevel = std::process::Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()?;
    if toplevel.status.success() {
        let s = String::from_utf8_lossy(&toplevel.stdout).trim().to_string();
        if !s.is_empty() {
            return Ok(PathBuf::from(s));
        }
    }
    Ok(PathBuf::from("."))
}

/// Walk `<root>/docs/gaps/*.yaml` and load each entry as a generic
/// `serde_yaml::Value`. Returns `(gap_id -> Value)`.
///
/// Mirrors `gap-doctor.py::load_yaml_status`. Per-file layout is the
/// post-INFRA-188 canonical shape; the legacy monolithic
/// `docs/gaps.yaml` is not consulted (and is typically `.gitignored`).
///
/// Each file is a one-element YAML list (the chump dump shape) OR a
/// single mapping. Both shapes are accepted to match the Python loader's
/// tolerance.
pub fn load_yaml_status_map(
    root: &Path,
) -> std::io::Result<std::collections::BTreeMap<String, serde_yaml::Value>> {
    let mut out = std::collections::BTreeMap::new();
    let dir = root.join("docs").join("gaps");
    if !dir.is_dir() {
        return Ok(out);
    }
    let mut entries: Vec<_> = std::fs::read_dir(&dir)?
        .filter_map(|r| r.ok())
        .filter(|e| {
            e.path()
                .extension()
                .and_then(|s| s.to_str())
                .map(|ext| ext.eq_ignore_ascii_case("yaml"))
                .unwrap_or(false)
        })
        .collect();
    entries.sort_by_key(|e| e.path());

    for entry in entries {
        let path = entry.path();
        let text = match std::fs::read_to_string(&path) {
            Ok(t) => t,
            Err(_) => continue,
        };
        let parsed: serde_yaml::Value = match serde_yaml::from_str(&text) {
            Ok(v) => v,
            Err(_) => continue, // matches Python's `except Exception: continue`
        };
        let entries_iter: Vec<serde_yaml::Value> = match parsed {
            serde_yaml::Value::Sequence(seq) => seq,
            serde_yaml::Value::Mapping(_) => vec![parsed],
            _ => continue,
        };
        for v in entries_iter {
            if let serde_yaml::Value::Mapping(m) = &v {
                if let Some(serde_yaml::Value::String(id)) =
                    m.get(serde_yaml::Value::String("id".to_string()))
                {
                    out.insert(id.clone(), v);
                }
            }
        }
    }
    Ok(out)
}

/// Extract `status` from a YAML gap value, defaulting to empty string.
/// Helper for callers that don't need full GapRow conversion.
pub fn yaml_status(v: &serde_yaml::Value) -> String {
    v.get("status")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string()
}

/// Extract `closed_date` from a YAML gap value (matching the Python loader's
/// tolerance for date-typed YAML values). Returns empty string when absent.
pub fn yaml_closed_date(v: &serde_yaml::Value) -> String {
    match v.get("closed_date") {
        Some(serde_yaml::Value::String(s)) => {
            s.trim().trim_matches('\'').trim_matches('"').to_string()
        }
        Some(other) => {
            // YAML date-typed value — serialize back to its scalar repr.
            // serde_yaml renders dates as ISO YYYY-MM-DD.
            serde_yaml::to_string(other)
                .unwrap_or_default()
                .trim()
                .trim_end_matches("\n...")
                .to_string()
        }
        None => String::new(),
    }
}

/// Extract `closed_pr` from a YAML gap value as a positive integer.
/// Returns `None` when absent, zero, or unparseable.
pub fn yaml_closed_pr(v: &serde_yaml::Value) -> Option<i64> {
    let raw = v.get("closed_pr")?;
    match raw {
        serde_yaml::Value::Number(n) => n.as_i64().filter(|x| *x > 0),
        serde_yaml::Value::String(s) => {
            let cleaned = s.trim().trim_matches('\'').trim_matches('"');
            cleaned.parse::<i64>().ok().filter(|x| *x > 0)
        }
        _ => None,
    }
}
