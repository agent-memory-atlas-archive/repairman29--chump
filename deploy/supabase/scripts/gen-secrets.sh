#!/usr/bin/env bash
# Generate the self-hosted Supabase secrets for cuphead into an env file OUTSIDE the repo.
# Mints POSTGRES_PASSWORD + JWT_SECRET, then the anon/service_role API keys as HS256 JWTs
# signed with JWT_SECRET (the Supabase convention). GOOGLE_* are left as placeholders for
# Jeff to paste (the OAuth client that stays with Google). NEVER commit the output file.
set -euo pipefail
ENV_FILE="${SUPABASE_ENV_FILE:-/srv/supabase-data/.env}"
FORCE="${1:-}"
if [[ -f "$ENV_FILE" && "$FORCE" != "--force" ]]; then
  echo "ERROR: $ENV_FILE already exists. Refusing to overwrite (pass --force to regenerate — this rotates all secrets)." >&2
  exit 1
fi
command -v openssl >/dev/null || { echo "need openssl" >&2; exit 1; }
command -v python3 >/dev/null || { echo "need python3" >&2; exit 1; }

POSTGRES_PASSWORD="$(openssl rand -hex 24)"
JWT_SECRET="$(openssl rand -hex 32)"

# Mint an HS256 Supabase API JWT for a given role, signed with JWT_SECRET.
mint_jwt() {
  local role="$1"
  JWT_SECRET="$JWT_SECRET" ROLE="$role" python3 - <<'PY'
import base64, hashlib, hmac, json, os, time
def b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=')
secret=os.environ['JWT_SECRET'].encode(); role=os.environ['ROLE']
now=int(time.time())
header=b64(json.dumps({"alg":"HS256","typ":"JWT"},separators=(',',':')).encode())
payload=b64(json.dumps({"role":role,"iss":"supabase","iat":now,"exp":now+10*365*24*3600},separators=(',',':')).encode())
signing=header+b'.'+payload
sig=b64(hmac.new(secret,signing,hashlib.sha256).digest())
print((signing+b'.'+sig).decode())
PY
}
SUPABASE_ANON_KEY="$(mint_jwt anon)"
SUPABASE_SERVICE_ROLE_KEY="$(mint_jwt service_role)"

umask 077
sudo mkdir -p "$(dirname "$ENV_FILE")"
sudo tee "$ENV_FILE" >/dev/null <<EOF
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
JWT_SECRET=$JWT_SECRET
SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY
SUPABASE_SERVICE_ROLE_KEY=$SUPABASE_SERVICE_ROLE_KEY
GOOGLE_CLIENT_ID=REPLACE_WITH_google_oauth_client_id
GOOGLE_CLIENT_SECRET=REPLACE_WITH_google_oauth_client_secret
STUDIO_BIND_ADDR=100.113.181.18
EOF
sudo chmod 600 "$ENV_FILE"
echo "Wrote $ENV_FILE (chmod 600). Fill GOOGLE_CLIENT_ID/SECRET, then run scripts/start-supabase.sh."