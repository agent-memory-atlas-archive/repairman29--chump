//! RESILIENT-1241 (RESILIENT-1230 slice): automatic restart for
//! `chump-fleet-health-sentinel.service` when systemd reports it `failed`.
//!
//! The sentinel itself is the thing that scans+heals other failed chump
//! units (`scripts/ops/fleet-health-sentinel.sh`) — nothing was watching
//! the watchman. This module adds that outer loop: query the unit's
//! `ActiveState` via the systemd client (real impl shells out to
//! `systemctl --user show`, mirroring how it's installed in
//! `scripts/setup/install-fleet-health-sentinel.sh`), and issue
//! `systemctl --user restart <unit>` when the state is `failed`.
//!
//! The `SystemdClient` trait exists so the restart decision logic can be
//! integration-tested against a mock without a real systemd/DBus session
//! (CI runners frequently have neither).

use anyhow::Result;

/// Minimal systemd surface this monitor needs. The real implementation
/// talks to systemd over its DBus API via `systemctl`, which is itself a
/// thin DBus client — shelling out avoids pulling a DBus binding into the
/// dependency graph for a single-unit health check.
pub trait SystemdClient {
    /// Returns the unit's `ActiveState` (e.g. "active", "failed", "inactive").
    fn active_state(&self, unit: &str) -> Result<String>;

    /// Issues a restart for the given unit.
    fn restart(&self, unit: &str) -> Result<()>;
}

/// Real systemd client: shells out to `systemctl --user`.
pub struct RealSystemdClient;

impl SystemdClient for RealSystemdClient {
    fn active_state(&self, unit: &str) -> Result<String> {
        let out = std::process::Command::new("systemctl")
            .args(["--user", "show", "--property=ActiveState", "--value", unit])
            .output()?;
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    }

    fn restart(&self, unit: &str) -> Result<()> {
        std::process::Command::new("systemctl")
            .args(["--user", "restart", unit])
            .status()?;
        Ok(())
    }
}

/// Checks `unit`'s active state via `client`; if it is `failed`, issues a
/// restart. Returns `true` iff a restart was attempted.
pub fn restart_if_failed(client: &dyn SystemdClient, unit: &str) -> Result<bool> {
    let state = client.active_state(unit)?;
    if state == "failed" {
        client.restart(unit)?;
        return Ok(true);
    }
    Ok(false)
}

/// The unit this monitor watches (RESILIENT-1230 slice).
pub const SENTINEL_UNIT: &str = "chump-fleet-health-sentinel.service";

/// `chump sentinel-service-restart check` — one-shot: check `SENTINEL_UNIT`
/// and restart it if `failed`. Returns process exit code.
pub fn run_cli(_args: &[String]) -> i32 {
    let client = RealSystemdClient;
    match restart_if_failed(&client, SENTINEL_UNIT) {
        Ok(true) => {
            println!("{SENTINEL_UNIT} was failed — restart issued");
            0
        }
        Ok(false) => {
            println!("{SENTINEL_UNIT} is not failed — no action");
            0
        }
        Err(e) => {
            eprintln!("sentinel-service-restart: error checking {SENTINEL_UNIT}: {e:#}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::HashMap;

    /// Mock systemd client (AC #3): fixed active states per unit, and a
    /// log of restart calls so the test can assert on intent, not shell
    /// side effects.
    struct MockSystemdClient {
        states: HashMap<String, String>,
        restarts: RefCell<Vec<String>>,
    }

    impl MockSystemdClient {
        fn new(state: &str) -> Self {
            let mut states = HashMap::new();
            states.insert(SENTINEL_UNIT.to_string(), state.to_string());
            Self {
                states,
                restarts: RefCell::new(Vec::new()),
            }
        }
    }

    impl SystemdClient for MockSystemdClient {
        fn active_state(&self, unit: &str) -> Result<String> {
            Ok(self
                .states
                .get(unit)
                .cloned()
                .unwrap_or_else(|| "inactive".to_string()))
        }

        fn restart(&self, unit: &str) -> Result<()> {
            self.restarts.borrow_mut().push(unit.to_string());
            Ok(())
        }
    }

    #[test]
    fn restarts_when_failed() {
        let client = MockSystemdClient::new("failed");
        let attempted = restart_if_failed(&client, SENTINEL_UNIT).unwrap();
        assert!(attempted, "expected a restart to be attempted");
        assert_eq!(client.restarts.borrow().as_slice(), [SENTINEL_UNIT]);
    }

    #[test]
    fn no_restart_when_active() {
        let client = MockSystemdClient::new("active");
        let attempted = restart_if_failed(&client, SENTINEL_UNIT).unwrap();
        assert!(!attempted, "did not expect a restart when unit is active");
        assert!(client.restarts.borrow().is_empty());
    }

    #[test]
    fn no_restart_when_inactive() {
        let client = MockSystemdClient::new("inactive");
        let attempted = restart_if_failed(&client, SENTINEL_UNIT).unwrap();
        assert!(!attempted);
        assert!(client.restarts.borrow().is_empty());
    }
}
