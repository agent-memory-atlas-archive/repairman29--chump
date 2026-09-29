#!/usr/bin/env bash
# Prove the newest backup restores: for each app database, load its dump into a throwaway
# DB `restore_scratch`, compare auth.users + public.items counts and the freshness canary
# against live, then drop the scratch DB. Pass a timestamp (e.g. 20260927T000019Z) to pick a run.
set -euo pipefail
DIR=/srv/supabase-data/backups
TS=${1:-$(ls -1t $DIR/postgres_*.dump | head -1 | sed -E 's/.*postgres_(.*)\.dump/\1/')}
psql(){ docker exec -i supabase_postgres psql -U supabase_admin -v ON_ERROR_STOP=1 -Atq "$@"; }
Q="select 'canary', taken from ops.backup_canary union all
   select 'auth.users', count(*)::text from auth.users union all
   select 'items', count(*)::text from public.items order by 1"
bad=0
for db in smuggler postsub trove_web pov_video; do
  psql -d postgres -c 'DROP DATABASE IF EXISTS restore_scratch'
  psql -d postgres -c 'CREATE DATABASE restore_scratch'
  docker exec -i supabase_postgres pg_restore -U supabase_admin -d restore_scratch --no-owner < "$DIR/${db}_$TS.dump" 2>>/tmp/restore-test.err || true
  live=$(psql -d "$db" -c "$Q" | tr '\n' ' '); scratch=$(psql -d restore_scratch -c "$Q" | tr '\n' ' ')
  if [[ "$live" == "$scratch" && "$scratch" == *"canary|$TS"* ]]; then echo "RESTORE OK  $db: $scratch"
  else echo "RESTORE BAD $db: live=[$live] scratch=[$scratch]"; bad=1; fi
done
psql -d postgres -c 'DROP DATABASE IF EXISTS restore_scratch'
exit $bad
