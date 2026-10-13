# Duty Officer Service Configuration — User Bus Environment (RESILIENT-1294)

## Overview

The `chump-duty-officer.service` systemd unit manages the standing incident-response loop that reads firing health signals and routes them to appropriate action tiers. To interact with systemd user services (via `systemctl --user`), the duty officer process requires two critical environment variables that define the **user bus session**: `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS`.

This document explains:
- What these variables do and why they matter
- The drop-in approach for providing them (RESILIENT-1297 fallback logic)
- The fallback behavior when the systemd unit doesn't set them
- How to diagnose and troubleshoot user-bus connectivity issues

---

## Critical Environment Variables

### `XDG_RUNTIME_DIR`

**Purpose:** Defines the base runtime directory for the current user's session. The systemd user manager, the D-Bus session bus, and other user-session services store runtime files and sockets here.

**Standard path:** `/run/user/<UID>` where `<UID>` is the numeric user ID (e.g., `/run/user/1000` for UID 1000).

**Why it matters for duty-officer:**
- The systemd user manager stores socket files in `${XDG_RUNTIME_DIR}/systemd/private`
- The D-Bus session bus socket lives at `${XDG_RUNTIME_DIR}/bus` (by default)
- Without this, `systemctl --user` cannot reach the user-scoped systemd session and fails with "Cannot get user bus" or "No such file or directory"

### `DBUS_SESSION_BUS_ADDRESS`

**Purpose:** Explicit address of the D-Bus session bus socket that `systemctl --user` and other user-session tools use to communicate with the user-session systemd instance.

**Standard format:** `unix:path=/run/user/<UID>/bus` (or for abstract sockets, `unix:abstract=/run/user/<UID>/bus`)

**Why it matters for duty-officer:**
- Allows `systemctl --user` to connect to the user-scoped systemd manager
- Must be set for the duty officer's system health checks (e.g., health-sentinel timer status)
- Without this, D-Bus tools fail to locate the session bus and commands like `systemctl --user is-active chump-fleet-health-sentinel.timer` fail

---

## The Drop-in Approach (RESILIENT-1297 Fallback)

The duty-officer-loop.sh script (`scripts/coord/duty-officer-loop.sh`) implements **defensive initialization** via the `_ensure_user_bus_env()` function (lines 90–98). This fallback provides the environment variables whenever they are missing:

```bash
_ensure_user_bus_env() {
    if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
        export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    fi
    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
    fi
}
_ensure_user_bus_env
```

### How It Works

1. **Check for existing values:** If `XDG_RUNTIME_DIR` or `DBUS_SESSION_BUS_ADDRESS` are already set (e.g., by the systemd unit or the launcher), those values are used as-is.
2. **Derive from running UID:** If not set, the script derives them from the numeric user ID of the process running the script (`id -u`).
3. **Set and export:** The derived values are exported into the process environment so all child processes inherit them.

### Why This Matters

The fallback was added because the original `chump-duty-officer.service` hardcoded a single UID (RESILIENT-1294), breaking whenever the unit ran under a different user. This fallback allows the **same service unit** to work correctly on any user's session.

---

## Service Unit Configuration

### Default Setup (systemd service file)

The `chump-duty-officer.service` file (in `scripts/dispatch/`) uses the helsinki convention (written for `/root`). When installed via `chump-node-install.sh`, the unit is rewritten to match the actual run-user:

```ini
[Unit]
Description=Chump duty-officer — route firing health signals T1 auto-heal / T2 runbook / T3 page
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=HOME=/root
Environment=CHUMP_REPO_ROOT=/root/Projects/chump
Environment=CHUMP_DUTY_OFFICER_EXECUTE=1
ExecStart=/bin/bash -lc "set -a; source /root/.chump/providers.env 2>/dev/null; set +a; cd /root/Projects/chump; exec bash scripts/coord/duty-officer-loop.sh tick"
TimeoutStartSec=300
```

After installation, `HOME`, `CHUMP_REPO_ROOT`, and the `ExecStart` path are rewritten to the actual user's home directory (e.g., `/home/ubuntu`).

### Recommended Drop-in Override

If you need to explicitly set `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS` for a specific user or environment, create a drop-in override in systemd:

```bash
# Create the drop-in directory (replace USERNAME with the actual user)
mkdir -p /etc/systemd/user/chump-duty-officer.service.d

# Create the override file
cat > /etc/systemd/user/chump-duty-officer.service.d/override.conf << 'EOF'
[Service]
Environment="XDG_RUNTIME_DIR=/run/user/1000"
Environment="DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
EOF

# Reload systemd to pick up the override
systemctl --user daemon-reload
```

This approach:
- Survives service unit updates (drop-ins are not overwritten by package upgrades)
- Takes precedence over values set in the main service file
- Allows per-environment customization without editing the main unit

---

## Troubleshooting User-Bus Connectivity

### Check Current Values

```bash
# In your shell session, check the current values
echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
echo "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS"

# For a specific user (e.g., ubuntu)
sudo -u ubuntu bash -c 'echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"; echo "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS"'
```

### Verify User-Session Systemd is Running

```bash
# Check if the user manager is active
systemctl --user is-system-running
# Expected output: running, degraded (but alive), or offline

# List user-session services
systemctl --user list-units --type=service
```

### Verify the D-Bus Socket Exists

```bash
# Check if the bus socket file exists and is accessible
ls -la "$XDG_RUNTIME_DIR/bus"
# Expected: a socket file (-s in ls output)

# If the socket is missing, the user-session may not be initialized
# Bring it up with loginctl:
loginctl enable-linger $(whoami)  # Ensure user session survives logout
systemctl --user start dbus       # Explicitly start the D-Bus service
```

### Run Duty-Officer Manually with Debug Output

```bash
# Export the environment variables explicitly
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

# Run the script with verbose output
bash -x scripts/coord/duty-officer-loop.sh tick
```

### Common Failure Modes

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| `Cannot get user bus` | `DBUS_SESSION_BUS_ADDRESS` not set or wrong | Set it via systemd override or manually export |
| `No such file or directory` (socket) | `XDG_RUNTIME_DIR` points to non-existent path | Verify `/run/user/<UID>` exists; run `loginctl enable-linger` |
| `systemctl --user` commands hang or timeout | User-session systemd is not running | Restart with `systemctl --user start dbus` or reboot |
| Duty-officer unit runs but health checks fail | Child processes don't inherit the bus env | Ensure the variables are exported (not just set) |

---

## For Container / Non-systemd Environments

If the duty-officer script runs outside a traditional systemd user session (e.g., in a Docker container or on a system without systemd), the fallback logic in `_ensure_user_bus_env()` will still apply:

- It derives `XDG_RUNTIME_DIR` from the running UID
- It constructs a valid D-Bus address format
- The script continues but systemd user commands (e.g., `systemctl --user`) will fail if the user-session bus is not actually live

For containers, this is expected behavior. The fallback ensures the script doesn't crash on missing environment variables; whether the derived paths are valid depends on the container's systemd setup.

---

## Related Gaps and References

- **RESILIENT-1297** — The duty-officer fallback implementation (lines 90–98 of duty-officer-loop.sh)
- **RESILIENT-1294** — The original gap: document the user-bus environment requirements
- **RESILIENT-1258** — Health-sentinel timer (related user-session systemd work)
- **RESILIENT-1050** — Cold-install FTUE with user-session systemd in Docker
- **LINUX_NODE_ONBOARDING.md** — Full node setup procedure (sets up user-session)
- **COTG_NODE_INSTALL.md** — Bare-metal counterpart (explains user-session setup)

---

## Summary

The `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS` environment variables are **required** for the duty-officer service to interact with user-scoped systemd units. The `scripts/coord/duty-officer-loop.sh` script includes a **fallback initialization** that derives these variables if they are not already set, making the same service unit portable across different user IDs and environments. This approach (RESILIENT-1297) solved the single-UID hardcoding problem and ensures the duty-officer works on any owned node without manual per-user configuration.
