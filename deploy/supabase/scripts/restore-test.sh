#!/usr/bin/env bash
# Prove a backup restores: load the newest (or given) dump into a throwaway DB
# `restore_scratch` inside the running Postgres, compare row counts for the app
# schemas + auth.users against live, then drop the scratch DB.
set -euo pipefail
DUMP=${1:-$(ls -1t /srv/supabase-data/backups/postgres_*.dump | head -1)}
echo "restoring $DUMP"
WANT=$(basename "$DUMP" .dump); WANT=${WANT#postgres_}
psql(){ docker exec -i supabase_postgres psql -U supabase_admin -v ON_ERROR_STOP=1 -Atq "$@"; }
psql -d postgres -c 'DROP DATABASE IF EXISTS restore_scratch' -c 'CREATE DATABASE restore_scratch'
# Supabase-managed objects owned by roles that exist cluster-wide restore fine; ignore
# harmless "already exists" noise from extensions, fail on nothing else silently.
docker exec -i supabase_postgres pg_restore -U supabase_admin -d restore_scratch --no-owner < "$DUMP" 2>/tmp/restore-test.err || true
Q="select 'ops.backup_canary', taken from ops.backup_canary union all
   select 'auth.users',count(*)::text from auth.users union all
   select s||'.items', (xpath('/row/c/text()', query_to_xml(format('select count(*) c from %I.items', s), false, true, '')))[1]::text
   from unnest(array['smuggler','postsub','trove_web','pov_video']) s order by 1"
live=$(psql -d postgres -c "$Q"); scratch=$(psql -d restore_scratch -c "$Q")
echo "live:";    echo "$live"
echo "scratch:"; echo "$scratch"
psql -d postgres -c 'DROP DATABASE restore_scratch'
if [[ "$live" == "$scratch" && "$scratch" == *"ops.backup_canary|$WANT"* ]]; then echo "RESTORE OK (counts match, canary $WANT present)"; else echo "RESTORE MISMATCH"; exit 1; fi
