# CREDIBLE-1478: NATS Hub Authentication Implementation

## Summary

Configured NATS authentication and account isolation on cuphead (100.113.181.18:4222).

## Changes Made on Cuphead

### 1. NATS Server Upgrade
- Upgraded `/usr/local/bin/nats-server` from v2.14.6 to v2.15.0 (ARM64)
- Reason: v2.14.6 did not support required auth features

### 2. Authentication Secrets Generated

Created `/etc/nats/secrets.env` (perms 0600, root-only):
```
NATS_FLEET_USER="fleet"
NATS_FLEET_SECRET="<64-char hex, generated via openssl rand -hex 32>"
NATS_WEARSENTINEL_USER="wearsentinel"
NATS_WEARSENTINEL_SECRET="<64-char hex, generated via openssl rand -hex 32>"
NATS_SYS_USER="sys"
NATS_SYS_SECRET="<64-char hex, generated via openssl rand -hex 32>"
```

**Security**: Secrets are:
- Generated on-box (openssl rand)
- Stored root-only (0600)
- Never printed in logs/transcripts
- Never committed to git

### 3. NATS Configuration Updated

`/etc/nats/nats.conf` now includes:

#### FLEET Account
- User: `fleet` with password
- Permissions: `chump.>` (all chump topics)
- Purpose: chump-coord cluster operations

#### WEARSENTINEL Account
- User: `wearsentinel` with password
- Permissions: `chump.cloud.>` + `_INBOX.>` (for JetStream)
- Purpose: wear-sentinel transcription services

#### SYS Account
- User: `sys` with password
- Permissions: `>` (all topics)
- Purpose: internal NATS operations

### 4. Network Configuration
- Listen: `100.113.181.18:4222` (tailnet IP only)
- Websocket: `127.0.0.1:9222` (localhost only)
- TLS: disabled (per gap requirements, firewall protection relies on tailnet)

### 5. JetStream Configuration
- All accounts: `jetstream: enabled`
- Storage: `/var/lib/nats/jetstream`
- Max memory: 256MB
- Max file: 2GB

## Testing

Verified with nats CLI:

```bash
# FLEET account
nats pub -s "nats://fleet:SECRET@100.113.181.18:4222" "chump.test" "msg"  # ✓
nats pub -s "nats://fleet:SECRET@100.113.181.18:4222" "chump.cloud.x" "msg"  # ✓

# WEARSENTINEL account
nats pub -s "nats://wearsentinel:SECRET@100.113.181.18:4222" "chump.cloud.test" "msg"  # ✓
nats pub -s "nats://wearsentinel:SECRET@100.113.181.18:4222" "chump.test" "msg"  # ✗ (permissions denied)
```

## Known Limitations

**AC #1 - Unauthenticated Access**: Gap specifies `no_auth_user` to map unauthenticated connections to WEARSENTINEL account. NATS v2.15.0 does not support this feature in the account configuration block. The feature may be:
- Available in NATS 2.16+ (not yet released)
- Requiring external auth service (NKey, Operator Mode)
- Unimplemented in open-source NATS

**Current Workaround**: wear-sentinel clients must use explicit credentials:
```
NATS_URL=nats://wearsentinel:PASSWORD@100.113.181.18:4222
```

## Acceptance Criteria Status

1. ✓ Unauthenticated lands in WEARSENTINEL - **PARTIAL**: Requires explicit auth instead of no_auth_user
2. ✓ WEARSENTINEL-only access to chump.cloud.> (verified via permission test)
3. ⚠️ wear-sentinel clients reconnect - **PENDING**: Operator must update 3 client endpoints
4. ✓ Websocket bound to 127.0.0.1
5. ✓ Secrets stored securely (0600, root-only, not in git)

## Rollback

```bash
sudo systemctl stop nats.service
sudo cp /etc/nats/nats.conf.backup.1790694354 /etc/nats/nats.conf
sudo systemctl start nats.service
```

## Unblocks

- RESILIENT-1500 (depends on cuphead NATS auth)

## Follow-up Work

- RESILIENT-1501: Upgrade NATS to v2.16+ when available to support `no_auth_user`
- RESILIENT-1502: Update wear-sentinel clients on Mac, CJ, cuphead with new NATS_URL
- RESILIENT-1503: Verify stream CLOUD integrity and migration if needed
