# HOLLER Service Setup (MISSION-111)

The holler service is a systemd-based alert emission system that provisions the `HOLLER_SERVICE_KEY` from a secret manager or environment file and enables timer-based alert emission without manual key insertion.

## Overview

- **Service unit:** `holler.service` — loads `HOLLER_SERVICE_KEY` from env file and initializes alert emission
- **Timer unit:** `holler.timer` — fires the holler service every 5 minutes to check and emit alert conditions
- **Initialization script:** `scripts/ops/holler-init.sh` — handles key loading and validation
- **Configuration:** `~/.chump/holler.env` — stores the service key and optional settings

## Setup Steps

### 1. Prepare the Secret

Obtain your `HOLLER_SERVICE_KEY` from your alert service provider or secret manager.

### 2. Create the Configuration File

Copy the example configuration and fill in your key:

```bash
cp scripts/dispatch/holler.env.example ~/.chump/holler.env
chmod 600 ~/.chump/holler.env
```

Edit `~/.chump/holler.env` and set `HOLLER_SERVICE_KEY`:

```bash
HOLLER_SERVICE_KEY="your-actual-service-key"
```

### 3. Enable the Service

Enable and start the holler timer:

```bash
systemctl enable --now holler.timer
```

### 4. Verify Setup

Check the service status:

```bash
systemctl status holler.timer
systemctl status holler.service
systemctl list-timers holler.timer
```

Check the logs:

```bash
journalctl -u holler.service -n 20 -f
tail -f /var/log/holler.log
```

## How It Works

1. **Boot:** `holler.timer` fires and activates `holler.service`
2. **Initialization:** `holler.service` calls `scripts/ops/holler-init.sh`
3. **Key Loading:** `holler-init.sh` loads `HOLLER_SERVICE_KEY` from:
   - Environment variable `HOLLER_SERVICE_KEY` (if set), or
   - File `~/.chump/holler-key` (if it exists), or
   - Sourced from `~/.chump/holler.env` (preferred)
4. **Validation:** Key is validated to ensure it's non-empty
5. **Initialization:** Service marks holler as initialized via `/var/run/holler-initialized`
6. **Recurring:** Timer re-fires every 5 minutes to maintain alert emission

## Security Considerations

- **File Permissions:** Keep `~/.chump/holler.env` with mode `0600` to prevent unauthorized access
- **Key Rotation:** Update the key in `holler.env` and reload:
  ```bash
  systemctl restart holler.timer
  ```
- **Alternative Storage:** For production, use a proper secret manager (e.g., systemd's `LoadCredential=`) instead of plaintext env file

## Troubleshooting

### Service fails to start
- Check that `~/.chump/holler.env` exists and is readable
- Verify `HOLLER_SERVICE_KEY` is set and non-empty
- Check logs: `journalctl -u holler.service`

### Timer not firing
- Verify timer is enabled: `systemctl list-timers holler.timer`
- Check `AccuracySec=1s` and `OnUnitInactiveSec=5m` are set correctly
- Restart the timer: `systemctl restart holler.timer`

### Key not being loaded
- Verify `holler.env` is sourced correctly in the service file
- Check file permissions: `ls -la ~/.chump/holler.env`
- Test sourcing manually: `source ~/.chump/holler.env && echo $HOLLER_SERVICE_KEY`

## Related Documentation

- MISSION-111: Automate HOLLER_SERVICE_KEY provisioning and enable timer
- MISSION-103: Parent umbrella gap (Holler integration)
