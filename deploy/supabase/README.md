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

## Separate user bases (one stack per app)

Decision (Jeff, 2026-09-26): each app keeps its **own** user base and its own "Sign in with Google"
client. So there is one Postgres *cluster* but **one database per app** (own `auth.users`, own
`storage` schema), and each app has its own GoTrue + PostgREST + Storage containers and its **own
JWT secret and keys**. A token or user from one app is rejected by every other app
(`smoke-test.sh` checks this). Apps are listed in `apps.conf`; `scripts/render.py` generates
`docker-compose.yml` and `Caddyfile` from it (edit `apps.conf`, never the generated files).
Each app can later move to hosted Supabase alone by swapping URL + keys.

| App (database) | Public API host | Loopback ports rest / auth / storage |
|---|---|---|
| smuggler | api.playsmuggler.com | 54331 / 9991 / 5001 |
| postsub | api.postsub.io | 54332 / 9992 / 5002 |
| trove_web | api.mytrove.app | 54333 / 9993 / 5003 |
| pov_video | api.sendpov.xyz | 54334 / 9994 / 5004 |

## Deploy on a fresh cuphead

```bash
# prereqs (see workspace-docs GCP_EXIT.md): 50GB volume at /srv/supabase-data, 4GB swapfile,
# ports 80/443 open (VCN + host iptables), api.* DNS -> cuphead, docker + compose plugin,
# earlyoom, and Caddy from the official apt repo (arm64! an amd64 /usr/bin/caddy was the
# reason HTTPS silently never came up the first time).
sudo rsync -a deploy/supabase/ /opt/supabase/        # stable path, NOT a worktree (reapers)
bash /opt/supabase/scripts/gen-secrets.sh            # /srv/supabase-data/.env (chmod 600): postgres pw
bash /opt/supabase/scripts/gen-app-secrets.sh        # + per-app JWT secret / anon / service keys
sudo mkdir -p /srv/supabase-data/storage/{smuggler,postsub,trove_web,pov_video} && sudo chown -R 1000:1000 /srv/supabase-data/storage
sudo cp /opt/supabase/systemd/* /etc/systemd/system/ && sudo systemctl daemon-reload
sudo systemctl enable --now supabase-stack caddy-supabase supabase-backup.timer
for h in api.playsmuggler.com api.postsub.io api.mytrove.app api.sendpov.xyz; do /opt/supabase/scripts/smoke-test.sh $h; done
sudo systemctl start supabase-backup && /opt/supabase/scripts/restore-test.sh
```

Google sign-in per app: put that app's own OAuth client in `GOOGLE_CLIENT_ID_<APP>` /
`GOOGLE_CLIENT_SECRET_<APP>`, set `GOOGLE_ENABLED_<APP>=true`, redirect URI
`https://<api host>/auth/v1/callback`, then `systemctl restart supabase-stack`.

## What runs

| Unit / service | Where | Notes |
|---|---|---|
| `supabase.slice` | MemoryHigh 3.5G, **MemoryMax 4G**, swap max 1G | containers join via `cgroup_parent` (systemd-run around compose does NOT move containers). ~1.3 GB with 4 apps |
| `supabase-stack.service` | `docker compose up -d` from `/opt/supabase` | secrets from `/srv/supabase-data/.env` |
| Postgres | 127.0.0.1:54322, data `/srv/supabase-data/postgres`, `oom_score_adj -800` | never public; `postgres` DB is the pristine template the app DBs are cloned from at init |
| GoTrue ×4 | DB URL needs `search_path=auth`, or it migrates into `public` and breaks `auth` | |
| PostgREST ×4 | logs in as `authenticator` | |
| Storage ×4 | logs in as `supabase_storage_admin`, files `/srv/supabase-data/storage/<app>` | |
| Studio + pg-meta | **tailnet IP**:8000 | never public |
| `caddy-supabase.service` | :80/:443, Let's Encrypt | each host routes to its app's services; REST/Storage refuse requests with no apikey (Kong parity) |
| `supabase-backup.timer` | 09:30 UTC nightly | `scripts/backup.sh`: pg_dump of every DB as `supabase_admin` + storage tar + canary; OCI via write-only PAR, CJ via write-only rrsync key (targets in `/srv/supabase-data/backup.env`) |
| `earlyoom` | host | prefers killing cargo/rustc/node, avoids postgres/dockerd/sshd |

## Host prerequisites (not in compose; done once on cuphead, 2026-09-26)

- **earlyoom**: `apt install earlyoom`, `/etc/default/earlyoom`:
  `EARLYOOM_ARGS="-r 3600 -m 5 -s 10 --avoid (^|/)(init|systemd.*|sshd|tailscaled|dockerd|containerd|postgres)$ --prefer (^|/)(cargo|rustc|node)$"`
- **Caddy**: from the official apt repo (`dl.cloudsmith.io/public/caddy/stable`), so it is arm64. Disable the
  package's own `caddy.service`; `caddy-supabase.service` runs `/opt/supabase/Caddyfile` with
  `CAP_NET_BIND_SERVICE`. The old amd64 binary is parked at `/usr/local/share/caddy.amd64.broken`.
- **Swap**: 4 GB `/swapfile` (Oracle Ubuntu images ship with none).
- **Data volume**: 50 GB block volume at `/srv/supabase-data` (UUID + `nofail` in fstab).
- **Ingress**: 80/443 open in the VCN security list + host iptables. Note: host iptables also accepts 22 and
  8090 from anywhere; only the VCN security list keeps them off the internet (verified closed from off-box).

## Off-box backups (both live 2026-09-27)

`/srv/supabase-data/backup.env` (chmod 600, never committed) configures both targets:

| Target | How it authenticates | Scope |
|---|---|---|
| OCI Object Storage `cuphead-backups` (Phoenix, namespace per account) | pre-authenticated request `cuphead-nightly-backup-write`, created in the OCI console (bucket → Management → Pre-authenticated requests) | **object writes only**, no reads, no listing; **expires 2027-09-26**, then create a new one and replace `OCI_BACKUP_PAR_URL` |
| closetjunky `/mnt/cjdata1/backups/cuphead-supabase` | cuphead key `~/.ssh/cj_backup`; CJ `authorized_keys`: `command="/usr/bin/rrsync -wo /mnt/cjdata1/backups/cuphead-supabase",restrict,from="<cuphead tailnet IP>"` | write-only into that folder, no shell. Needs the tailnet policy grant `cuphead → closetjunky tcp:22` (plus a policy test asserting it) |

Retention: 14 days locally (`KEEP_DAYS`); OCI and CJ keep everything until pruned by hand (add an OCI
lifecycle rule if the 20 GB free tier gets tight).

## Google sign-in (one client per app, 2026-09-27)

Each app has its **own** sign-in-only GCP project (no billing needed), so user bases never mix:
`playsmuggler-auth`, `postsub-auth`, `mytrove-auth`, `sendpov-auth`. Each has Google Auth Platform branding
(External audience) and one Web client: origin `https://<site>`, redirect `https://<api host>/auth/v1/callback`.
Load a client with `echo "<app> <client_id> <secret>" | python3 scripts/set-google.py`, then
`sudo systemctl restart supabase-stack`. The apps are in **Testing** (max 100 test users): Google greys out
"Publish app" until the Branding page has a home page and a privacy policy URL. Do that per app before
real users arrive. Do not put these clients in the Firebase projects: those are being deleted.

## Where the secrets live (never their values)

| Secret | Location | Rotate by |
|---|---|---|
| Postgres password (all service roles) | `/srv/supabase-data/.env` `POSTGRES_PASSWORD` | `ALTER ROLE` for postgres, supabase_admin, authenticator, supabase_auth_admin, supabase_storage_admin, then restart |
| Per-app JWT secret + anon/service keys | `.env` `JWT_SECRET_<APP>`, `ANON_KEY_<APP>`, `SERVICE_ROLE_KEY_<APP>` | delete the app's lines, rerun `gen-app-secrets.sh`, restart, hand the new anon key to the app |
| Per-app Google client | `.env` `GOOGLE_CLIENT_ID/SECRET_<APP>` | new secret in that app's `*-auth` project → `set-google.py` |
| OCI backup PAR | `/srv/supabase-data/backup.env` | OCI console, see above |
| CJ backup key | cuphead `~/.ssh/cj_backup` + line in CJ `~/.ssh/authorized_keys` | new keypair, swap the CJ line |
| Legacy shared keys (`JWT_SECRET`, `SUPABASE_*_KEY`) | `.env`, unused since the per-app split | safe to delete |

## Proof runbook (run on cuphead)

```bash
for h in api.playsmuggler.com api.postsub.io api.mytrove.app api.sendpov.xyz; do /opt/supabase/scripts/smoke-test.sh $h; done
sudo systemctl start supabase-backup && journalctl -u supabase-backup -n 20 -o cat   # expect "oci ok" + "cj ok"
/opt/supabase/scripts/restore-test.sh                     # every app DB restores, canary matches
bash /opt/supabase/scripts/memory-spike-test.sh           # earlyoom kills a hog, postgres keeps its PID
```

Results 2026-09-27: smoke 19/19 on all four hosts; backup 7/7 to OCI and CJ (CJ copies pass
`sha256sum -c`); restore OK ×4; 21 GB hog killed by earlyoom, Postgres not restarted.
Depth: happy-path + adversarial (RLS, cross-app isolation, no-apikey, memory pressure, restricted backup key).
Not yet covered: reboot survival, 24h fleet-worker throughput, a completed end-to-end Google login.
