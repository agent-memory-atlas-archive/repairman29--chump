#!/usr/bin/env bash
# Nightly backup for the cuphead Supabase stack (RESILIENT-314).
# 1. pg_dump (custom format, whole `postgres` DB incl. auth + storage schemas) via docker exec,
#    so no DB password ever touches the host shell.
# 2. tar of /srv/supabase-data/storage (file-backed Storage objects).
# 3. Off-box copies: OCI Object Storage bucket `cuphead-backups` via a write-only
#    pre-authenticated request URL, and closetjunky (CJ) via scp. Both optional,
#    both configured in /srv/supabase-data/backup.env (chmod 600, never committed):
#      OCI_BACKUP_PAR_URL=https://objectstorage.../p/<token>/n/<ns>/b/cuphead-backups/o/
#      CJ_BACKUP_TARGET=jeff@closetjunky:/mnt/cjdata1/backups/cuphead-supabase
# Exit non-zero if the local dump fails OR any configured off-box copy fails.
set -euo pipefail
CONF=/srv/supabase-data/backup.env
[[ -f $CONF ]] && source "$CONF"
DIR=/srv/supabase-data/backups
TS=$(date -u +%Y%m%dT%H%M%SZ)
KEEP_DAYS=${KEEP_DAYS:-14}
mkdir -p "$DIR"
log(){ echo "[$(date -u +%FT%TZ)] $*"; }

DB="$DIR/postgres_$TS.dump"
# Freshness canary in a schema PostgREST does not expose; restore-test.sh checks it survived.
docker exec supabase_postgres psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -q -c \
  "create schema if not exists ops; create table if not exists ops.backup_canary(id int primary key, taken text not null);
   insert into ops.backup_canary values (1,'$TS') on conflict (id) do update set taken=excluded.taken"
log "pg_dump -> $DB"
docker exec supabase_postgres pg_dump -U supabase_admin -d postgres -Fc > "$DB.part"
mv "$DB.part" "$DB"
[[ -s $DB ]] || { log "ERROR: empty dump"; exit 1; }

ST="$DIR/storage_$TS.tar.gz"
log "storage tar -> $ST"
tar -czf "$ST" -C /srv/supabase-data storage

sha256sum "$DB" "$ST" > "$DIR/SHA256SUMS_$TS"
fail=0
for f in "$DB" "$ST" "$DIR/SHA256SUMS_$TS"; do
  if [[ -n ${OCI_BACKUP_PAR_URL:-} ]]; then
    code=$(curl -sS -o /dev/null -w '%{http_code}' -X PUT --upload-file "$f" \
      "${OCI_BACKUP_PAR_URL%/}/supabase/$TS/$(basename "$f")") || code=000
    [[ $code == 200 ]] && log "oci ok $(basename "$f")" || { log "ERROR oci $code $(basename "$f")"; fail=1; }
  fi
  if [[ -n ${CJ_BACKUP_TARGET:-} ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=15 "${CJ_BACKUP_TARGET%%:*}" "mkdir -p '${CJ_BACKUP_TARGET#*:}/$TS'" \
      && scp -q -o BatchMode=yes "$f" "$CJ_BACKUP_TARGET/$TS/" \
      && log "cj ok $(basename "$f")" || { log "ERROR cj $(basename "$f")"; fail=1; }
  fi
done

find "$DIR" -maxdepth 1 -type f \( -name 'postgres_*.dump' -o -name 'storage_*.tar.gz' -o -name 'SHA256SUMS_*' \) -mtime +"$KEEP_DAYS" -delete
log "done (fail=$fail) $(du -h "$DB" | cut -f1) db, $(du -h "$ST" | cut -f1) storage"
exit $fail
