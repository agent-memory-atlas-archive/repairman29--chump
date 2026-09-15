//! RESILIENT-1241 (RESILIENT-1230 slice): automatic restart for
//! `chump-fleet-health-sentinel.service` when it reports `failed`.
//!
//! `systemctl` itself talks to systemd over the system/session D-Bus API
//! (`org.freedesktop.systemd1`) — the `SystemdClient` trait below is the
//! seam that lets tests swap in a mock instead of shelling out to the real
//! `systemctl` binary.

use std::process::Command;

/// Default unit name for the fleet health sentinel.
pub const DEFAULT_SENTINEL_UNIT: &str = "chump-fleet-health-sentinel.service";

/// Abstraction over the systemd D-Bus API surface this monitor needs:
/// query a unit's `ActiveState` and issue a restart.
pub trait SystemdClient {
    /// Returns true if the unit's `ActiveState` is `failed`.
    fn is_failed(&self, unit: &str) -> bool;

    /// Issues a restart for the given unit. Returns Ok(()) if the restart
    /// command was accepted.
    fn restart(&self, unit: &str) -> Result<(), String>;
}

/// Real `SystemdClient` backed by the `systemctl` CLI, which queries and
/// mutates unit state via systemd's D-Bus API under the hood.
pub struct RealSystemdClient {
    systemctl_bin: String,
}

impl RealSystemdClient {
    pub fn new() -> Self {
        Self {
            systemctl_bin: std::env::var("CHUMP_HEALTH_SENTINEL_SYSTEMCTL_BIN")
                .unwrap_or_else(|_| "systemctl".to_string()),
        }
    }
}

impl Default for RealSystemdClient {
    fn default() -> Self {
        Self::new()
    }
}

impl SystemdClient for RealSystemdClient {
    fn is_failed(&self, unit: &str) -> bool {
        let output = Command::new(&self.systemctl_bin)
            .args(["--user", "show", "--property=ActiveState", unit])
            .output();
        match output {
            Ok(out) => {
                let state = String::from_utf8_lossy(&out.stdout);
                state.trim() == "ActiveState=failed"
            }
            Err(_) => false,
        }
    }

    fn restart(&self, unit: &str) -> Result<(), String> {
        Command::new(&self.systemctl_bin)
            .args(["--user", "restart", unit])
            .status()
            .map_err(|e| format!("failed to invoke systemctl restart {unit}: {e}"))
            .and_then(|status| {
                if status.success() {
                    Ok(())
                } else {
                    Err(format!("systemctl restart {unit} exited with {status}"))
                }
            })
    }
}

/// Outcome of one monitor pass, for logging/ambient-emit callers.
#[derive(Debug, PartialEq, Eq)]
pub enum MonitorOutcome {
    /// Unit was not in `failed` state; no action taken.
    Healthy,
    /// Unit was `failed`; a restart was issued successfully.
    Restarted,
    /// Unit was `failed`; the restart attempt itself errored.
    RestartFailed(String),
}

/// Detect a `failed` unit via the systemd D-Bus API and, if found, issue a
/// `systemctl restart` for it (RESILIENT-1241, AC1+AC2).
pub fn check_and_restart(client: &dyn SystemdClient, unit: &str) -> MonitorOutcome {
    if !client.is_failed(unit) {
        return MonitorOutcome::Healthy;
    }

    match client.restart(unit) {
        Ok(()) => MonitorOutcome::Restarted,
        Err(e) => MonitorOutcome::RestartFailed(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    /// Mock systemd client (AC3): scripted failed-state + restart tracking,
    /// no real systemctl/D-Bus calls.
    struct MockSystemdClient {
        failed_units: Vec<String>,
        restart_calls: RefCell<Vec<String>>,
        restart_result: Result<(), String>,
    }

    impl MockSystemdClient {
        fn new(failed_units: &[&str]) -> Self {
            Self {
                failed_units: failed_units.iter().map(|s| s.to_string()).collect(),
                restart_calls: RefCell::new(Vec::new()),
                restart_result: Ok(()),
            }
        }

        fn with_restart_failure(mut self, reason: &str) -> Self {
            self.restart_result = Err(reason.to_string());
            self
        }
    }

    impl SystemdClient for MockSystemdClient {
        fn is_failed(&self, unit: &str) -> bool {
            self.failed_units.iter().any(|u| u == unit)
        }

        fn restart(&self, unit: &str) -> Result<(), String> {
            self.restart_calls.borrow_mut().push(unit.to_string());
            self.restart_result.clone()
        }
    }

    #[test]
    fn restarts_unit_reported_failed() {
        let client = MockSystemdClient::new(&[DEFAULT_SENTINEL_UNIT]);
        let outcome = check_and_restart(&client, DEFAULT_SENTINEL_UNIT);

        assert_eq!(outcome, MonitorOutcome::Restarted);
        assert_eq!(
            client.restart_calls.borrow().as_slice(),
            &[DEFAULT_SENTINEL_UNIT.to_string()]
        );
    }

    #[test]
    fn does_not_restart_healthy_unit() {
        let client = MockSystemdClient::new(&[]);
        let outcome = check_and_restart(&client, DEFAULT_SENTINEL_UNIT);

        assert_eq!(outcome, MonitorOutcome::Healthy);
        assert!(client.restart_calls.borrow().is_empty());
    }

    #[test]
    fn surfaces_restart_failure() {
        let client = MockSystemdClient::new(&[DEFAULT_SENTINEL_UNIT])
            .with_restart_failure("dbus call rejected");
        let outcome = check_and_restart(&client, DEFAULT_SENTINEL_UNIT);

        assert_eq!(
            outcome,
            MonitorOutcome::RestartFailed("dbus call rejected".to_string())
        );
        assert_eq!(client.restart_calls.borrow().len(), 1);
    }

    #[test]
    fn ignores_other_units() {
        let client = MockSystemdClient::new(&["some-other.service"]);
        let outcome = check_and_restart(&client, DEFAULT_SENTINEL_UNIT);

        assert_eq!(outcome, MonitorOutcome::Healthy);
        assert!(client.restart_calls.borrow().is_empty());
    }
}
