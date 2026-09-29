#!/usr/bin/env python3
# Put one app's OWN Google OAuth client into /srv/supabase-data/.env and enable Google sign-in for it.
# Reads "<app> <client_id> <client_secret>" on STDIN (never argv, so it stays out of ps/shell history).
#   echo "postsub <id> <secret>" | python3 set-google.py && sudo systemctl restart supabase-stack
import sys,re
app,cid,sec=sys.stdin.read().split()
p='/srv/supabase-data/.env'; s=open(p).read(); U=app.upper()
def put(k,v):
    global s
    if re.search(rf'^{k}=.*$',s,re.M): s=re.sub(rf'^{k}=.*$',f'{k}={v}',s,flags=re.M)
    else: s+=f'\n{k}={v}\n' if not s.endswith('\n') else f'{k}={v}\n'
put(f'GOOGLE_CLIENT_ID_{U}',cid); put(f'GOOGLE_CLIENT_SECRET_{U}',sec); put(f'GOOGLE_ENABLED_{U}','true')
open(p,'w').write(s); print('set',U,'id_len',len(cid),'secret_len',len(sec))
