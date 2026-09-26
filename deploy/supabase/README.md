# Self-hosted Supabase on cuphead (RESILIENT-314)

Self-hosted Supabase OSS on **cuphead** (Oracle Always-Free A1, us-phoenix-1) — the
data + auth layer for the tiny apps being migrated off Firebase (smuggler, postsub,
trove-web, pov-video). Part of the GCP exit (`workspace-docs/GCP_EXIT.md`).

## Security model (this is a PUBLIC repo)

- **No secrets are committed.** `docker-compose.yml` reads every credential via `${VAR}`.
- Secrets live only in `/srv/supabase-data/.env` (chmod 600, **gitignored**, off the repo).
- `.env.example` documents the variables; `scripts/gen-secrets.sh` generates a real `.env`
  (random `POSTGRES_PASSWORD`/`JWT_SECRET`, then mints the anon/service_role API keys as
  HS256 JWTs signed with `JWT_SECRET`). Only `GOOGLE_CLIENT_ID/SECRET` are pasted by hand
  ("Sign in with Google" stays with Google).

## Deploy on a fresh cuphead

```bash
# prereqs (see workspace-docs GCP_EXIT.md): 50GB volume at /srv/supabase-data, 4GB swapfile,
# ports 80/443 open (VCN + host iptables), api.* DNS -> cuphead, docker + compose plugin,
# earlyoom, and Caddy from the official apt repo (arm64! an amd64 /usr/bin/caddy was the
# reason HTTPS silently never came up the first time).
sudo rsync -a deploy/supabase/ /opt/supabase/        # stable path, NOT a worktree (reapers)
bash /opt/supabase/scripts/gen-secrets.sh            # writes /srv/supabase-data/.env (chmod 600)
sudo cp /opt/supabase/systemd/* /etc/systemd/system/ && sudo systemctl daemon-reload
sudo systemctl enable --now supabase-stack caddy-supabase supabase-backup.timer
/opt/supabase/scripts/smoke-test.sh                  # 17 end-to-end checks through public TLS
sudo systemctl start supabase-backup && /opt/supabase/scripts/restore-test.sh
```

## What runs

| Unit / service | Where | Notes |
|---|---|---|
| `supabase.slice` | MemoryHigh 3.5G, **MemoryMax 4G**, swap max 1G | containers join via `cgroup_parent` in compose (systemd-run around compose does NOT move containers) |
| `supabase-stack.service` | `docker compose up -d` from `/opt/supabase` | secrets from `/srv/supabase-data/.env` |
| Postgres | 127.0.0.1:54322, data `/srv/supabase-data/postgres` | never public |
| PostgREST | 127.0.0.1:54321 | schemas public, smuggler, postsub, trove_web, pov_video |
| GoTrue | 127.0.0.1:9999 | DB URL needs `search_path=auth`, or it migrates into `public` and breaks `auth` |
| Storage | 127.0.0.1:5000, files `/srv/supabase-data/storage` | |
| Studio | **tailnet IP**:8000 | never public |
| `caddy-supabase.service` | :80/:443, Let's Encrypt | `/rest/v1` `/auth/v1` `/storage/v1` on the four `api.*` hosts; REST/Storage refuse requests with no apikey (Kong parity) |
| `supabase-backup.timer` | 09:30 UTC nightly | `scripts/backup.sh`: pg_dump as `supabase_admin` (`postgres` is not a real superuser in this image) + storage tar; off-box targets in `/srv/supabase-data/backup.env` |
| `earlyoom` | host | prefers killing cargo/rustc/node, avoids postgres/dockerd/sshd |
