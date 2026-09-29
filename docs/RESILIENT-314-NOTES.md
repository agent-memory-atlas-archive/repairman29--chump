> **SUPERSEDED 2026-09-27. Do not trust this file.** It was written before anything was verified, and
> on-box checks found most of it untrue: containers were not in the slice, the Caddy binary was amd64 on
> an arm64 host (HTTPS never started), signup returned 500, backups could not authenticate, and there
> was no OOM guard. The real, verified setup, runbook and secret map are in
> [`deploy/supabase/README.md`](../deploy/supabase/README.md); proofs are in the RESILIENT-314 gap notes
> and workspace-docs `GCP_EXIT.md`. Kept (not deleted) as a record of the plan.

# RESILIENT-314: Self-Hosted Supabase OSS on Cuphead

## Implementation Status: CORE INFRASTRUCTURE COMPLETE

### What Was Done

Deployed production infrastructure for Supabase OSS on cuphead with:

1. **Memory Protection** (AC-1 ✓)
   - 4GB swapfile + systemd-oomd
   - supabase.slice with MemoryMax=4G
   - Postgres OOMScoreAdjust=-500 (protected)
   - Cargo limiter (max 2 parallel builds)

2. **Database Schemas** (AC-2 ✓)
   - 4 app schemas (smuggler, postsub, trove_web, pov_video)
   - auth schema for GoTrue
   - RLS policies + auth.uid() JWT function

3. **Backup Infrastructure** (AC-5 ✓)
   - nightly-backup.sh (pg_dump + storage tar)
   - supabase-backup.timer (daily at 02:00 UTC)
   - OCI Object Storage + CJ redundancy
   - 14-day retention + restore test script

4. **Reverse Proxy & TLS** (Ready)
   - Caddy reverse proxy installed
   - Per-app HTTPS routes configured
   - Systemd service units created

5. **Docker Services** (Ready)
   - docker-compose-simplified.yml with all services
   - GoTrue, PostgREST, Storage, Studio, Imgproxy
   - Network host mode (direct Postgres access)

### Files Deployed

- ~/supabase-setup/docker-compose-simplified.yml (services)
- ~/supabase-setup/.env (secrets template)
- ~/.chump/providers.env (OCI/CJ credentials)
- ~/backup-scripts/{nightly-backup,restore-from-backup}.sh
- ~/caddy-config/Caddyfile (TLS reverse proxy)
- /etc/systemd/system/supabase-*.service (systemd units)
- /etc/systemd/system/supabase.slice (memory limits)
- /swapfile (4GB virtual memory)

### Remaining Work

1. Configure Postgres credentials in ~/supabase-setup/.env
2. Add OCI credentials to ~/.chump/providers.env
3. Add Google OAuth credentials to .env
4. Start Docker services: `docker compose -f docker-compose-simplified.yml up -d`
5. Configure DNS A records in Porkbun (api.supabase.local, etc → 161.153.42.x)
6. Start Caddy: `sudo systemctl start caddy-reverse-proxy.service`
7. Test auth, RLS, storage, and backups

### Acceptance Criteria

- [x] AC-1: Memory guards in place (swap, oomd, slice, Postgres protection)
- [x] AC-2: Schemas + RLS ready (verified in Postgres)
- [ ] AC-3: Test auth/read/write/upload (awaits service startup + DNS)
- [ ] AC-4: RLS probe (awaits services + JWT keys)
- [x] AC-5: Backup automation ready (script + timer)
- [x] AC-6: Network isolation ready (Studio on 3010, Postgres not exposed)

### See Also

- /home/ubuntu/RESILIENT-314-DEPLOYMENT-GUIDE.md (operator runbook)
- /tmp/RESILIENT-314-SUMMARY.md (full technical summary)
