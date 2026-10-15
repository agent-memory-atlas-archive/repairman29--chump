# Holler Service Setup (MISSION-111)

## Overview

The holler service provides automated provisioning of `HOLLER_SERVICE_KEY` and timer-based alert emission. It loads the service key from a secret manager or environment file at boot time, eliminating manual key insertion requirements.

## Prerequisites

- systemd (Linux)
- Bash 4.0+
- sudo access (for system-wide installation) or user systemd directory (for user-level installation)

## Installation

### 1. Prepare the Configuration File

Copy the example configuration to your home directory and fill in your service key:

```bash
cp scripts/dispatch/holler.env.example ~/.chump/holler.env
# Edit ~/.chump/holler.env and set HOLLER_SERVICE_KEY to your actual key
chmod 600 ~/.chump/holler.env
```

**For system-wide installation** (requires root):

```bash
sudo cp scripts/dispatch/holler.env.example /root/.chump/holler.env
sudo chmod 600 /root/.chump/holler.env
# Edit /root/.chump/holler.env with the service key
```

### 2. Install systemd Units

The installation script validates prerequisites and installs the systemd units:

```bash
# Check prerequisites
bash scripts/setup/install-holler-systemd.sh --check

# Install for current user
bash scripts/setup/install-holler-systemd.sh

# Install system-wide (requires sudo)
sudo bash scripts/setup/install-holler-systemd.sh
```

### 3. Enable and Start the Timer

After installation, enable and start the timer:

```bash
# User-level
systemctl --user enable --now holler.timer

# System-wide
sudo systemctl enable --now holler.timer
```

## Verification

Verify the holler timer is running:

```bash
# User-level
systemctl --user list-timers holler.timer
systemctl --user status holler.service
journalctl --user-unit holler.service -n 20

# System-wide
sudo systemctl list-timers holler.timer
sudo systemctl status holler.service
sudo journalctl -u holler.service -n 20
```

## How It Works

1. **Timer Trigger** — `holler.timer` fires on boot (30 seconds after service start) and then every 5 minutes
2. **Service Execution** — `holler.service` runs as a oneshot unit that:
   - Loads `HOLLER_SERVICE_KEY` from `~/.chump/holler.env` (or `/root/.chump/holler.env` for system-wide)
   - Validates the key is non-empty
   - Initializes alert emission via `holler-init.sh`
   - Logs results to `/var/log/holler.log`
3. **Key Provisioning** — The key can be provided in three ways (checked in order):
   - Environment variable `HOLLER_SERVICE_KEY`
   - File at `HOLLER_KEY_FILE` (default: `/root/.chump/holler-key`)
   - Environment file sourced from `~/.chump/holler.env` or `/root/.chump/holler.env`

## Configuration Options

Edit `~/.chump/holler.env` (or `/root/.chump/holler.env`) to customize:

```bash
# Required: Service key for holler alert emission
HOLLER_SERVICE_KEY="your-service-key-here"

# Optional: Alert endpoint URL
HOLLER_ALERT_ENDPOINT="https://alerts.example.com/v1/emit"

# Optional: Log verbosity (info, debug, error)
HOLLER_LOG_LEVEL="info"

# Optional: Log file location
HOLLER_LOG="/var/log/holler.log"

# Optional: Key file location (alternative to env var)
HOLLER_KEY_FILE="/root/.chump/holler-key"
```

## Troubleshooting

### Service Fails to Start

Check the logs:
```bash
journalctl --user-unit holler.service -xe
# or
sudo journalctl -u holler.service -xe
```

Common issues:
- **Missing config file** — Ensure `~/.chump/holler.env` exists and is readable
- **Missing key** — Set `HOLLER_SERVICE_KEY` in the config file or via environment
- **Permission denied** — Make sure `~/.chump/holler.env` has correct permissions (`chmod 600`)

### Timer Not Firing

Check timer status:
```bash
systemctl --user list-timers --all holler.timer
# or
sudo systemctl list-timers --all holler.timer
```

Reset the timer:
```bash
systemctl --user restart holler.timer
# or
sudo systemctl restart holler.timer
```

### Checking the Holler Log

```bash
tail -f /var/log/holler.log
```

## Boot-Time Verification

To verify holler starts successfully on boot:

1. Install and enable the timer (steps above)
2. Reboot the system
3. Verify the service ran:
   ```bash
   journalctl --user-unit holler.service -n 10
   # or
   sudo journalctl -u holler.service -n 10
   ```

## Acceptance Criteria Status

✅ AC1: HOLLER_SERVICE_KEY is loaded from a secret manager or env file during service start
✅ AC2: holler.service and holler.timer units are added and enabled
✅ AC3: Holler starts successfully on boot without manual key insertion

## Related Files

- `scripts/dispatch/holler.service` — systemd service unit
- `scripts/dispatch/holler.timer` — systemd timer unit
- `scripts/dispatch/holler.env.example` — Configuration template
- `scripts/ops/holler-init.sh` — Service initialization script
- `scripts/setup/install-holler-systemd.sh` — Installation script
