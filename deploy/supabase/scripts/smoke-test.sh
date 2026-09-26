#!/usr/bin/env bash
# End-to-end proof for the cuphead Supabase stack (RESILIENT-314). Run ON cuphead:
# keys are read from /srv/supabase-data/.env and never leave the box.
# Goes through the public hostname + Caddy TLS (resolved to the public IP).
set -uo pipefail
set -a; source /srv/supabase-data/.env; set +a
H=${1:-api.postsub.io}; B=https://$H; IP=${PUBLIC_IP:-$(getent ahostsv4 "$H" | awk "NR==1{print \$1}")}; R=(--resolve "$H:443:$IP" -sS --max-time 15)
pass=0; fail=0; ok(){ echo "PASS $*"; pass=$((pass+1)); }; bad(){ echo "FAIL $*"; fail=$((fail+1)); }
chk(){ [[ "$2" == "$3" ]] && ok "$1 ($2)" || bad "$1 (got $2, want $3)"; }
J(){ python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

chk "auth health" "$(curl "${R[@]}" -o /dev/null -w '%{http_code}' $B/auth/v1/health)" 200
EMAIL="r314-probe-$(date +%s)@example.com"; PW="Probe-$(openssl rand -hex 8)"
AK=(-H "apikey: $SUPABASE_ANON_KEY" -H "Content-Type: application/json")
chk "signup" "$(curl "${R[@]}" -X POST $B/auth/v1/signup "${AK[@]}" -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\"}" | J '"ok" if d.get("id") or d.get("user",{}).get("id") else d')" ok
TOK=$(curl "${R[@]}" -X POST "$B/auth/v1/token?grant_type=password" "${AK[@]}" -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\"}" | J 'd.get("access_token","")')
chk "login returns JWT" "$([[ ${#TOK} -gt 100 ]] && echo yes || echo no)" yes
chk "wrong password rejected" "$(curl "${R[@]}" -o /dev/null -w '%{http_code}' -X POST "$B/auth/v1/token?grant_type=password" "${AK[@]}" -d "{\"email\":\"$EMAIL\",\"password\":\"wrong-pass-1\"}")" 400
chk "/auth/v1/user with JWT" "$(curl "${R[@]}" $B/auth/v1/user -H "apikey: $SUPABASE_ANON_KEY" -H "Authorization: Bearer $TOK" | J 'd.get("email")')" "$EMAIL"
for s in smuggler postsub trove_web pov_video; do
  chk "$s anon sees 0 private rows" "$(curl "${R[@]}" "$B/rest/v1/items?select=is_private" -H "apikey: $SUPABASE_ANON_KEY" -H "Accept-Profile: $s" | J 'sum(1 for r in d if r["is_private"])')" 0
  chk "$s authed sees private row" "$(curl "${R[@]}" "$B/rest/v1/items?select=is_private" -H "apikey: $SUPABASE_ANON_KEY" -H "Authorization: Bearer $TOK" -H "Accept-Profile: $s" | J 'sum(1 for r in d if r["is_private"])')" 1
done
chk "no-apikey REST refused" "$(curl "${R[@]}" -o /dev/null -w '%{http_code}' "$B/rest/v1/items" -H "Accept-Profile: postsub")" 401
chk "anon write refused" "$(curl "${R[@]}" -o /dev/null -w '%{http_code}' -X POST "$B/rest/v1/items" "${AK[@]}" -H "Content-Profile: postsub" -d '{"title":"anon-write"}')" 401
chk "auth schema not exposed via REST" "$(curl "${R[@]}" -o /dev/null -w '%{http_code}' "$B/rest/v1/users" -H "apikey: $SUPABASE_ANON_KEY" -H "Accept-Profile: auth")" 406
chk "Postgres not public" "$(timeout 5 bash -c "</dev/tcp/$IP/54322" 2>/dev/null && echo open || echo closed)" closed
# Storage round trip over public HTTPS: private bucket, user uploads, anon cannot read, owner can.
SK=(-H "apikey: $SUPABASE_SERVICE_ROLE_KEY" -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY")
curl "${R[@]}" -o /dev/null -X POST $B/storage/v1/bucket "${SK[@]}" -H "Content-Type: application/json" -d '{"id":"smoke","name":"smoke","public":false}'
OBJ="probe-$(date +%s).txt"; BODY="r314 storage probe $OBJ"
chk "storage upload (service)" "$(printf %s "$BODY" | curl "${R[@]}" -o /dev/null -w '%{http_code}' -X POST "$B/storage/v1/object/smoke/$OBJ" "${SK[@]}" -H 'Content-Type: text/plain' --data-binary @-)" 200
chk "storage download (service)" "$(curl "${R[@]}" "$B/storage/v1/object/smoke/$OBJ" "${SK[@]}")" "$BODY"
chk "storage anon read refused" "$(curl "${R[@]}" -o /dev/null -w '%{http_code}' "$B/storage/v1/object/smoke/$OBJ" -H "apikey: $SUPABASE_ANON_KEY" -H "Authorization: Bearer $SUPABASE_ANON_KEY")" 400
curl "${R[@]}" -o /dev/null -X DELETE "$B/storage/v1/object/smoke/$OBJ" "${SK[@]}"
# clean up the probe user
UID_=$(curl "${R[@]}" $B/auth/v1/user -H "apikey: $SUPABASE_ANON_KEY" -H "Authorization: Bearer $TOK" | J 'd.get("id")')
curl "${R[@]}" -o /dev/null -X DELETE "$B/auth/v1/admin/users/$UID_" -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY"
echo "== $pass passed, $fail failed"; exit $((fail>0))
