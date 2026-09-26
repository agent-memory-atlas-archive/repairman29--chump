-- App-level bootstrap for the self-hosted Supabase stack.
--
-- IMPORTANT ordering: the supabase/postgres image ships its OWN init scripts
-- under /docker-entrypoint-initdb.d/init-scripts/ that create the role trio
-- (anon / authenticated / service_role), the `auth` schema, and the
-- auth.uid()/auth.role() helpers. This file is mounted as `zz-app-init.sql`
-- so it runs AFTER those. Therefore it must NOT recreate roles or auth
-- helpers — it only layers the per-app schemas + RLS demo on top.

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Per-app schemas, each with an example RLS-protected `items` table.
--   anon          -> may read only rows where is_private = false
--   authenticated -> may read all rows and insert their own
--   service_role  -> BYPASSRLS (trusted server key), full access
DO $bootstrap$
DECLARE
  s text;
BEGIN
  FOREACH s IN ARRAY ARRAY['smuggler','postsub','trove_web','pov_video']
  LOOP
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', s);
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO anon, authenticated, service_role', s);

    EXECUTE format($f$
      CREATE TABLE IF NOT EXISTS %I.items (
        id         uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
        owner      uuid,
        title      text NOT NULL,
        is_private boolean NOT NULL DEFAULT false,
        created_at timestamptz NOT NULL DEFAULT now()
      )$f$, s);

    EXECUTE format('ALTER TABLE %I.items ENABLE ROW LEVEL SECURITY', s);

    EXECUTE format('DROP POLICY IF EXISTS anon_read_public ON %I.items', s);
    EXECUTE format($f$
      CREATE POLICY anon_read_public ON %I.items
        FOR SELECT TO anon
        USING (is_private = false)$f$, s);

    EXECUTE format('DROP POLICY IF EXISTS auth_read_all ON %I.items', s);
    EXECUTE format($f$
      CREATE POLICY auth_read_all ON %I.items
        FOR SELECT TO authenticated
        USING (true)$f$, s);

    EXECUTE format('DROP POLICY IF EXISTS auth_write_own ON %I.items', s);
    EXECUTE format($f$
      CREATE POLICY auth_write_own ON %I.items
        FOR INSERT TO authenticated
        WITH CHECK (owner = auth.uid())$f$, s);

    EXECUTE format('GRANT SELECT ON %I.items TO anon', s);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I.items TO authenticated', s);
    EXECUTE format('GRANT ALL ON %I.items TO service_role', s);

    -- Seed one public + one private row so RLS behaviour is demonstrable.
    EXECUTE format($f$
      INSERT INTO %I.items (title, is_private) VALUES
        ('public seed row', false),
        ('PRIVATE seed row', true)$f$, s);
  END LOOP;
END
$bootstrap$;
