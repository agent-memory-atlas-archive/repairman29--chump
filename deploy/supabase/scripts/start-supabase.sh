#!/usr/bin/env bash
# Bring up the self-hosted Supabase stack under the memory-limited supabase.slice.
#
# Secrets are read from an --env-file OUTSIDE the repo (never committed).
# Generate that file first with scripts/gen-secrets.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${SUPABASE_ENV_FILE:-/srv/supabase-data/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: env file $ENV_FILE not found. Run scripts/gen-secrets.sh first." >&2
  exit 1
fi

# Ensure data dirs exist with the ownership each image expects.
sudo mkdir -p /srv/supabase-data/postgres /srv/supabase-data/storage /srv/supabase-data/backups
# Postgres image runs as uid 999; storage-api as uid 1000.
if [[ -z "$(sudo ls -A /srv/supabase-data/postgres 2>/dev/null)" ]]; then
  sudo chown -R 999:999 /srv/supabase-data/postgres
fi
sudo chown -R 1000:1000 /srv/supabase-data/storage 2>/dev/null || true

cd "$HERE"
echo "Starting Supabase under supabase.slice (MemoryMax from the slice unit)..."
# systemd-run places the compose project's containers under the memory-limited
# slice. Compose itself daemonizes the containers (-d).
exec sudo systemd-run \
  --slice=supabase.slice \
  --property=Delegate=yes \
  --collect \
  --unit=supabase-compose-up \
  docker compose --env-file "$ENV_FILE" -f "$HERE/docker-compose.yml" up -d
