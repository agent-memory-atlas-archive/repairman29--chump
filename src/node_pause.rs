//! RESILIENT-1652 / RESILIENT-1653 (PHASE-R R6): the ONE paused predicate.
//!
//! Before this module the fleet detected a node pause in places that did not
//! agree:
//!   * `farmer_status::node_is_paused` read `node.env` for `CHUMP_NODE_MODE=paused`
//!     ONLY — it did not recognise the legacy `control-plane` + `WORK_ENABLED=0`
//!     form cuphead was actually paused with, so the farmer gate saw the node as
//!     UN-paused and walled every bot-merge re-entry (RESILIENT-1652 evidence);
//!   * `node_mode::is_paused` read `node.env` directly;
//!   * `node-converge.sh` had its own shell-only rule.
//!
//! This module owns the invariant (Rust-owns-invariants, PHASE-R R6): one
//! predicate that the pause/resume verb (writer), the farmer gate
//! (`farmer_status`), the pause detector (`node_mode`), `chump node is-paused`,
//! and node-converge (through `chump node is-paused`) all share. Every path is
//! resolved from the node **state dir** (`CHUMP_STATE_DIR`, else
//! `<state-home>/.chump`) — the same `sd` node-converge's `_nc_paused` uses.
//!
//! Two pause files exist and MUST NOT be conflated — they live under different
//! roots, so they never collide on a real node (state_dir ≠ repo):
//!
//!   * the **node pause sentinel** `<state_dir>/.chump/fleet-paused` — the
//!     operator pause. `chump node pause` WRITES it (with `REASON=…`),
//!     `chump node resume` REMOVES it, and node-converge's `_nc_paused` READS
//!     it. [`node_sentinel_path`] is the ONE function every writer and reader
//!     derives it from, so no reader ever checks a path no writer writes
//!     (RESILIENT-1653 AC2). It is a pause SIGNAL: the farmer gate reports
//!     PAUSED and ADMITS re-entry of already-claimed ship work (RESILIENT-1636).
//!
//!   * the **farmer kill switch** `<repo>/.chump/fleet-paused` — owned by the
//!     ci-health-gate / waste-SLO path, read by `farmer_status::check_sentinel`.
//!     It is a HARD RED the farmer gate never relaxes (the RESILIENT-1636 RED2
//!     invariant), so `chump node pause` MUST NOT write it — doing so would wall
//!     every re-entry on a verb-paused node. It is NOT this module's concern.
//!
//! The node sentinel being a pause SIGNAL here only affects reporting (`farmer
//! status` prints PAUSED, the stale heartbeat is attributed to the pause); the
//! kill switch independently drives `sentinel_absent=false` in the farmer gate.

use std::path::{Path, PathBuf};

/// Why a node reads as paused. The farmer gate uses this to attribute the
/// refusal reason accurately (node-env pause vs. the node pause sentinel).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PauseSignal {
    /// `node.env` expresses the pause (`CHUMP_NODE_MODE=paused`, or the legacy
    /// `control-plane` + `CHUMP_NODE_WORK_ENABLED=0` form).
    NodeEnv,
    /// the `<state_dir>/.chump/fleet-paused` node pause sentinel is present.
    Sentinel,
}

/// The ONE node pause sentinel path every writer and reader shares:
/// `<state_dir>/.chump/fleet-paused`. `chump node pause` writes it (carrying
/// `REASON=…`), `chump node resume` removes it, and the predicate + node-converge
/// read it. This is a DIFFERENT file from the farmer kill switch
/// `<repo>/.chump/fleet-paused` (owned by the ci-health-gate; a HARD RED): the
/// two live under distinct roots and must not be conflated. Routing every
/// access through this function is RESILIENT-1653 AC2's "no reader may check a
/// path no writer writes" guarantee (proved by `writer_and_reader_agree_*`).
pub fn node_sentinel_path(state_dir: &Path) -> PathBuf {
    state_dir.join(".chump").join("fleet-paused")
}

/// `node.env`'s path for a given state dir: `<state_dir>/node.env` — where
/// `chump node pause` writes `CHUMP_NODE_MODE` and node-converge's `_nc_paused`
/// reads it.
pub fn node_env_path(state_dir: &Path) -> PathBuf {
    state_dir.join("node.env")
}

/// Pure parse of a `node.env` body for a pause, in BOTH line forms:
///   * `CHUMP_NODE_MODE=paused` or `export CHUMP_NODE_MODE=paused`; OR
///   * the legacy `CHUMP_NODE_MODE=control-plane` (bare or `export`) together
///     with `CHUMP_NODE_WORK_ENABLED=0` (bare or `export`) — the 2026-10-17
///     hand-edit cuphead carried.
///
/// Pure (no fs/env) so it is deterministically unit-testable.
pub fn node_env_is_paused(content: &str) -> bool {
    let mut mode: Option<&str> = None;
    let mut work_enabled: Option<&str> = None;
    for line in content.lines() {
        let t = line.trim();
        // Accept the shell `export ` prefix (shells source node.env); systemd
        // EnvironmentFile units read the bare form (INFRA-8588). Honour both.
        let t = t.strip_prefix("export ").map(str::trim_start).unwrap_or(t);
        if let Some(v) = t.strip_prefix("CHUMP_NODE_MODE=") {
            mode = Some(v.trim());
        } else if let Some(v) = t.strip_prefix("CHUMP_NODE_WORK_ENABLED=") {
            work_enabled = Some(v.trim());
        }
    }
    if mode == Some("paused") {
        return true;
    }
    // Legacy control-plane pause: BOTH the mode and the work-enabled=0 knob.
    mode == Some("control-plane") && work_enabled == Some("0")
}

/// Resolve the pause signal from the node **state dir**: `node.env`
/// `CHUMP_NODE_MODE` (both line forms + the legacy control-plane form) wins the
/// attribution when present, else the `<state_dir>/.chump/fleet-paused` node
/// pause sentinel. `None` when neither expresses a pause.
pub fn pause_signal(state_dir: &Path) -> Option<PauseSignal> {
    if let Ok(body) = std::fs::read_to_string(node_env_path(state_dir)) {
        if node_env_is_paused(&body) {
            return Some(PauseSignal::NodeEnv);
        }
    }
    if node_sentinel_path(state_dir).exists() {
        return Some(PauseSignal::Sentinel);
    }
    None
}

/// The ONE paused predicate: true when the node state dir expresses a pause via
/// `node.env` (both line forms + the legacy control-plane form) OR the
/// `<state_dir>/.chump/fleet-paused` node pause sentinel exists. Shared by the
/// farmer gate (`farmer_status`), the pause detector (`node_mode`), and
/// `chump node is-paused`.
pub fn is_paused(state_dir: &Path) -> bool {
    pause_signal(state_dir).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mode_paused_both_line_forms() {
        assert!(node_env_is_paused("CHUMP_NODE_MODE=paused"));
        assert!(node_env_is_paused("export CHUMP_NODE_MODE=paused\n"));
        assert!(node_env_is_paused("  export CHUMP_NODE_MODE=paused  \n"));
        assert!(node_env_is_paused(
            "# header\nCHUMP_STATE_DIR=/x\nCHUMP_NODE_MODE=paused\n"
        ));
    }

    #[test]
    fn work_ready_is_not_paused() {
        assert!(!node_env_is_paused("CHUMP_NODE_MODE=work-ready\n"));
        assert!(!node_env_is_paused("export CHUMP_NODE_MODE=work-ready\n"));
        assert!(!node_env_is_paused("# comment\nexport FOO=bar\n"));
        assert!(!node_env_is_paused(""));
    }

    #[test]
    fn legacy_control_plane_plus_work_disabled_is_paused() {
        // The cuphead form (set 2026-10-17, before the pause verb existed).
        assert!(node_env_is_paused(
            "CHUMP_NODE_MODE=control-plane\nCHUMP_NODE_WORK_ENABLED=0\n"
        ));
        assert!(node_env_is_paused(
            "export CHUMP_NODE_MODE=control-plane\nexport CHUMP_NODE_WORK_ENABLED=0\n"
        ));
    }

    #[test]
    fn control_plane_without_work_disabled_is_not_paused() {
        // control-plane ALONE (work still enabled) is a running control node,
        // NOT a pause — the legacy form needs BOTH halves.
        assert!(!node_env_is_paused("CHUMP_NODE_MODE=control-plane\n"));
        assert!(!node_env_is_paused(
            "CHUMP_NODE_MODE=control-plane\nCHUMP_NODE_WORK_ENABLED=1\n"
        ));
        // WORK_ENABLED=0 without the control-plane mode is likewise not the
        // legacy pause form this predicate recognises.
        assert!(!node_env_is_paused(
            "CHUMP_NODE_MODE=work-ready\nCHUMP_NODE_WORK_ENABLED=0\n"
        ));
    }

    #[test]
    fn node_sentinel_path_is_state_dir_dot_chump() {
        // RESILIENT-1653 AC2: the node pause sentinel is exactly
        // `<state_dir>/.chump/fleet-paused` — the same `$sd/.chump/fleet-paused`
        // node-converge's `_nc_paused` reads. Never a doubled `.chump/.chump`.
        let p = node_sentinel_path(Path::new("/home/ubuntu/.chump"));
        assert_eq!(p, PathBuf::from("/home/ubuntu/.chump/.chump/fleet-paused"));
        assert!(p.ends_with(".chump/fleet-paused"));
    }

    #[test]
    fn pause_signal_reads_node_env_and_sentinel() {
        let state_buf =
            std::env::temp_dir().join(format!("chump-node-pause-test-1-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&state_buf);
        let state = state_buf.as_path();
        std::fs::create_dir_all(state.join(".chump")).unwrap();

        // Nothing paused yet.
        assert_eq!(pause_signal(state), None);
        assert!(!is_paused(state));

        // node.env pause → NodeEnv (attribution wins over sentinel).
        std::fs::write(node_env_path(state), "export CHUMP_NODE_MODE=paused\n").unwrap();
        assert_eq!(pause_signal(state), Some(PauseSignal::NodeEnv));
        assert!(is_paused(state));

        // sentinel only → Sentinel.
        std::fs::write(node_env_path(state), "CHUMP_NODE_MODE=work-ready\n").unwrap();
        std::fs::write(node_sentinel_path(state), "REASON=x\n").unwrap();
        assert_eq!(pause_signal(state), Some(PauseSignal::Sentinel));
        assert!(is_paused(state));

        // both present → NodeEnv attribution.
        std::fs::write(node_env_path(state), "CHUMP_NODE_MODE=paused\n").unwrap();
        assert_eq!(pause_signal(state), Some(PauseSignal::NodeEnv));
        let _ = std::fs::remove_dir_all(&state_buf);
    }

    #[test]
    fn writer_and_reader_agree_on_node_sentinel_path() {
        // RESILIENT-1653 AC2 / task (1): "no reader may check a path no writer
        // writes." A sentinel written at `node_sentinel_path(state_dir)` — the
        // ONE function the pause verb writes through — is seen by the predicate,
        // which reads through the SAME function. A doubled
        // `.chump/.chump/fleet-paused` is NOT where the reader looks.
        let state_buf =
            std::env::temp_dir().join(format!("chump-node-pause-test-2-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&state_buf);
        let state = state_buf.as_path();
        std::fs::create_dir_all(node_sentinel_path(state).parent().unwrap()).unwrap();
        std::fs::write(node_env_path(state), "CHUMP_NODE_MODE=work-ready\n").unwrap();
        // Write where the predicate reads → the predicate sees it.
        std::fs::write(node_sentinel_path(state), "REASON=slo_breach\n").unwrap();
        assert_eq!(pause_signal(state), Some(PauseSignal::Sentinel));
        // A doubled `.chump/.chump/fleet-paused` is NOT where the reader looks.
        std::fs::remove_file(node_sentinel_path(state)).unwrap();
        let doubled = state.join(".chump").join(".chump").join("fleet-paused");
        std::fs::create_dir_all(doubled.parent().unwrap()).unwrap();
        std::fs::write(&doubled, "REASON=slo_breach\n").unwrap();
        assert_eq!(pause_signal(state), None);
        let _ = std::fs::remove_dir_all(&state_buf);
    }
}
