#!/usr/bin/env bash
# Append per-app secrets to the env file (idempotent: apps that already have a JWT secret are
# skipped). Each app gets its own JWT_SECRET_<APP> and anon/service_role keys signed with it,
# so a token minted for one app is rejected by every other app.
set -euo pipefail
ENV_FILE="${SUPABASE_ENV_FILE:-/srv/supabase-data/.env}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mint() { JWT_SECRET="$1" ROLE="$2" python3 - <<'PY'
import base64,hashlib,hmac,json,os,time
b=lambda x: base64.urlsafe_b64encode(x).rstrip(b'=')
s=os.environ['JWT_SECRET'].encode(); now=int(time.time())
h=b(json.dumps({"alg":"HS256","typ":"JWT"},separators=(',',':')).encode())
p=b(json.dumps({"role":os.environ['ROLE'],"iss":"supabase","iat":now,"exp":now+10*365*24*3600},separators=(',',':')).encode())
print((h+b'.'+p+b'.'+b(hmac.new(s,h+b'.'+p,hashlib.sha256).digest())).decode())
PY
}
umask 077
grep -vE '^\s*(#|$)' "$HERE/apps.conf" | while read -r app _ _ _; do
  U=${app^^}
  grep -q "^JWT_SECRET_$U=" "$ENV_FILE" && { echo "skip $app (exists)"; continue; }
  sec=$(openssl rand -hex 32)
  { echo "JWT_SECRET_$U=$sec"
    echo "ANON_KEY_$U=$(mint "$sec" anon)"
    echo "SERVICE_ROLE_KEY_$U=$(mint "$sec" service_role)"
    echo "GOOGLE_CLIENT_ID_$U=REPLACE_WITH_google_oauth_client_id"
    echo "GOOGLE_CLIENT_SECRET_$U=REPLACE_WITH_google_oauth_client_secret"; } >> "$ENV_FILE"
  echo "added $app"
done
