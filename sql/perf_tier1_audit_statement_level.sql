-- Focus v7.9.37 — performance Tier 1, part 3: statement-level audit trigger
-- (2026-09-10). Rationale: Tier 1.4 in docs/perf-review/PERFORMANCE_REVIEW.md
-- (findings TRG-A1, TRG-A4).
--
-- audit_row_change (sql/add_audit_log.sql, extended with real_actor_id in
-- sql/add_passwords_and_masquerade.sql) runs FOR EACH ROW: per row it re-parses
-- the request headers, builds two full jsonb documents, hash-joins their keys
-- and inserts one audit_log row. A 12-month forecast upsert (v7.9.36) or a
-- 150-row bulk shift runs it 12 / 150 times inside the user's transaction.
--
-- This installs ONE function that does the same work per STATEMENT with
-- transition tables (Postgres 10+): identical audit_log rows, identical
-- x-actor-id / x-real-actor-id attribution, one call per statement. It then
-- re-attaches every table that currently carries a row-level audit_row_change
-- trigger AND has an `id` column (the UPDATE diff joins old and new rows on it).
-- Tables without `id` keep the row-level trigger. Idempotent; re-run safe.
--
-- Run LAST, on Dev first. Verify afterwards (see the bottom of this file).

BEGIN;

ALTER TABLE public.audit_log ADD COLUMN IF NOT EXISTS real_actor_id BIGINT REFERENCES public.people(id);

CREATE OR REPLACE FUNCTION public.audit_stmt() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_actor bigint;
  v_real  bigint;
BEGIN
  -- Actor from the PostgREST request headers (absent for direct SQL) — once per statement.
  BEGIN
    v_actor := nullif(nullif(current_setting('request.headers', true), '')::json->>'x-actor-id', '')::bigint;
  EXCEPTION WHEN OTHERS THEN v_actor := NULL;
  END;
  BEGIN
    v_real := nullif(nullif(current_setting('request.headers', true), '')::json->>'x-real-actor-id', '')::bigint;
  EXCEPTION WHEN OTHERS THEN v_real := NULL;
  END;
  IF v_real IS NOT NULL AND v_real = v_actor THEN v_real := NULL; END IF;

  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.audit_log (actor_id, real_actor_id, table_name, row_id, op, row_data)
    SELECT v_actor, v_real, TG_TABLE_NAME, nullif(to_jsonb(n)->>'id', '')::bigint, 'INSERT', to_jsonb(n)
      FROM new_rows n;

  ELSIF TG_OP = 'DELETE' THEN
    INSERT INTO public.audit_log (actor_id, real_actor_id, table_name, row_id, op, row_data)
    SELECT v_actor, v_real, TG_TABLE_NAME, nullif(to_jsonb(o)->>'id', '')::bigint, 'DELETE', to_jsonb(o)
      FROM old_rows o;

  ELSE
    -- Only the fields that actually changed; updated_at alone is noise, skip it.
    INSERT INTO public.audit_log (actor_id, real_actor_id, table_name, row_id, op, changes)
    SELECT v_actor, v_real, TG_TABLE_NAME, nullif(x.nj->>'id', '')::bigint, 'UPDATE', d.changes
      FROM (SELECT to_jsonb(n) AS nj, to_jsonb(o) AS oj
              FROM new_rows n
              JOIN old_rows o ON o.id = n.id) x
      CROSS JOIN LATERAL (
        SELECT jsonb_object_agg(k, jsonb_build_object('o', x.oj->k, 'n', x.nj->k)) AS changes
          FROM jsonb_object_keys(x.nj) k
         WHERE k <> 'updated_at'
           AND x.nj->k IS DISTINCT FROM x.oj->k) d
     WHERE d.changes IS NOT NULL;
  END IF;
  RETURN NULL;
END;
$$;

-- Re-attach: every table with a row-level audit_row_change trigger and an id column.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT DISTINCT c.relname AS tbl
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace ns ON ns.oid = c.relnamespace
      JOIN pg_proc p ON p.oid = t.tgfoid
     WHERE NOT t.tgisinternal
       AND ns.nspname = 'public'
       AND p.proname = 'audit_row_change'
       AND EXISTS (SELECT 1 FROM pg_attribute a
                    WHERE a.attrelid = c.oid AND a.attname = 'id' AND NOT a.attisdropped)
  LOOP
    -- the row-level trigger(s) calling audit_row_change on this table
    EXECUTE (
      SELECT string_agg(format('DROP TRIGGER IF EXISTS %I ON public.%I', t.tgname, r.tbl), '; ')
        FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
       WHERE t.tgrelid = ('public.' || quote_ident(r.tbl))::regclass
         AND NOT t.tgisinternal AND p.proname = 'audit_row_change');
    EXECUTE format('DROP TRIGGER IF EXISTS audit_ins_%1$I ON public.%1$I', r.tbl);
    EXECUTE format('DROP TRIGGER IF EXISTS audit_upd_%1$I ON public.%1$I', r.tbl);
    EXECUTE format('DROP TRIGGER IF EXISTS audit_del_%1$I ON public.%1$I', r.tbl);
    EXECUTE format('CREATE TRIGGER audit_ins_%1$I AFTER INSERT ON public.%1$I REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.audit_stmt()', r.tbl);
    EXECUTE format('CREATE TRIGGER audit_upd_%1$I AFTER UPDATE ON public.%1$I REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.audit_stmt()', r.tbl);
    EXECUTE format('CREATE TRIGGER audit_del_%1$I AFTER DELETE ON public.%1$I REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.audit_stmt()', r.tbl);
    RAISE NOTICE 'audit: % now statement-level', r.tbl;
  END LOOP;
END $$;

COMMIT;

-- Verify (Dev):
--   1. SELECT tgrelid::regclass, tgname FROM pg_trigger WHERE tgname LIKE 'audit_%' AND NOT tgisinternal ORDER BY 1, 2;
--      -- audit_ins_/audit_upd_/audit_del_ per table; no audit_<table> row-level ones left on tables with an id
--   2. Change a lead's notes in the app, then:
--      SELECT at, actor_id, real_actor_id, table_name, row_id, op, changes FROM audit_log ORDER BY id DESC LIMIT 3;
--      -- one UPDATE row for leads carrying {"notes": {"o": ..., "n": ...}}
--   3. Save a forecast: one audit row per month row written, produced by one statement.
--
-- Optional retention (audit_log grows without bound; pg_cron is available on Supabase):
--   CREATE EXTENSION IF NOT EXISTS pg_cron;
--   SELECT cron.schedule('focus_audit_retention', '15 2 * * *',
--     $$DELETE FROM public.audit_log WHERE at < now() - interval '18 months'$$);
