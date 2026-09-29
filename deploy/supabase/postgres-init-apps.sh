#!/bin/bash
# Runs once at initdb, AFTER the image's own init (roles, auth + storage schemas in `postgres`).
# Clones that pristine `postgres` DB into one database per app, so every app gets its own
# auth.users and storage schema. Connects to template1 so `postgres` has no sessions while
# it is used as the template.
set -euo pipefail
# The image only sets supabase_admin's password; PostgREST (authenticator) and Storage
# (supabase_storage_admin) log in as their own least-privilege roles, like hosted Supabase.
psql -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -v pw="$POSTGRES_PASSWORD" <<'SQL'
ALTER ROLE authenticator          WITH PASSWORD :'pw';
ALTER ROLE supabase_auth_admin    WITH PASSWORD :'pw';
ALTER ROLE supabase_storage_admin WITH PASSWORD :'pw';
SQL
for db in smuggler postsub trove_web pov_video; do
  psql -v ON_ERROR_STOP=1 -U supabase_admin -d template1 -c "CREATE DATABASE $db TEMPLATE postgres"
  psql -v ON_ERROR_STOP=1 -U supabase_admin -d "$db" <<'SQL'
-- RLS demo table used by scripts/smoke-test.sh: anon sees only public rows.
CREATE TABLE public.items (
  id uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  owner uuid, title text NOT NULL, is_private boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.items ENABLE ROW LEVEL SECURITY;
CREATE POLICY anon_read_public ON public.items FOR SELECT TO anon USING (is_private = false);
CREATE POLICY auth_read_all   ON public.items FOR SELECT TO authenticated USING (true);
CREATE POLICY auth_write_own  ON public.items FOR INSERT TO authenticated WITH CHECK (owner = auth.uid());
GRANT SELECT ON public.items TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.items TO authenticated;
GRANT ALL ON public.items TO service_role;
INSERT INTO public.items (title, is_private) VALUES ('public seed row', false), ('PRIVATE seed row', true);
-- Storage fixture for smoke-test.sh: a private `smoke` bucket where each user reads/writes only their own files.
INSERT INTO storage.buckets (id, name, public) VALUES ('smoke', 'smoke', false) ON CONFLICT (id) DO NOTHING;
CREATE POLICY smoke_insert_own ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'smoke' AND owner = auth.uid());
CREATE POLICY smoke_select_own ON storage.objects FOR SELECT TO authenticated USING (bucket_id = 'smoke' AND owner = auth.uid());
CREATE POLICY smoke_delete_own ON storage.objects FOR DELETE TO authenticated USING (bucket_id = 'smoke' AND owner = auth.uid());
SQL
done
