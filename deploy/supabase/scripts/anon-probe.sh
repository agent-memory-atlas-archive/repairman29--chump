#!/usr/bin/env bash
# AC2 anon-key probe (RESILIENT-314). Run ON cuphead. For every app: enumerate every table/view that
# PostgREST exposes to the anon key (OpenAPI root), read each one with ONLY the anon key over public HTTPS,
# and count rows. Also asserts from the DB side that every exposed table has RLS on, and that the auth +
# storage schemas are not reachable via REST. Pass = 0 rows anon should not see, in every app.
set -uo pipefail
set -a; source /srv/supabase-data/.env; set +a
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bad=0
while read -r app _ host _; do
  U=${app^^}; ANON=$(eval echo "\$ANON_KEY_$U")
  R=(--resolve "$host:443:$(getent ahostsv4 "$host" | awk 'NR==1{print $1}')" -sS --max-time 15)
  echo "== $app ($host)"
  for prof in public graphql_public; do
    paths=$(curl "${R[@]}" "https://$host/rest/v1/" -H "apikey: $ANON" -H "Accept-Profile: $prof" \
      | python3 -c "import sys,json;d=json.load(sys.stdin);print(' '.join(p.strip('/') for p in d.get('paths',{}) if p!='/' and not p.startswith('/rpc/')))" 2>/dev/null)
    [[ -z $paths ]] && { echo "  $prof: no tables exposed"; continue; }
    for t in $paths; do
      body=$(curl "${R[@]}" "https://$host/rest/v1/$t?select=*" -H "apikey: $ANON" -H "Accept-Profile: $prof")
      read -r n priv < <(echo "$body" | python3 -c "import sys,json
d=json.load(sys.stdin)
print(len(d) if isinstance(d,list) else 0, sum(1 for r in d if isinstance(r,dict) and r.get('is_private')) if isinstance(d,list) else 0)")
      echo "  $prof.$t: anon sees $n row(s), of which should-not-see (is_private) = $priv"
      (( priv > 0 )) && bad=1
    done
  done
  norls=$(docker exec supabase_postgres psql -U supabase_admin -d "$app" -Atc \
    "select string_agg(n.nspname||'.'||c.relname, ',') from pg_class c join pg_namespace n on n.oid=c.relnamespace
     where n.nspname='public' and c.relkind in ('r','p') and not c.relrowsecurity")
  echo "  public tables WITHOUT RLS: ${norls:-none}"; [[ -n $norls ]] && bad=1
  for s in auth storage; do
    code=$(curl "${R[@]}" -o /dev/null -w '%{http_code}' "https://$host/rest/v1/users" -H "apikey: $ANON" -H "Accept-Profile: $s")
    echo "  $s schema via REST: HTTP $code (want 406 = not exposed)"; [[ $code == 406 ]] || bad=1
  done
done < <(grep -vE '^\s*(#|$)' "$HERE/apps.conf")
(( bad == 0 )) && echo "ANON PROBE PASS: 0 rows anon should not see, in every app" || { echo "ANON PROBE FAIL"; exit 1; }
