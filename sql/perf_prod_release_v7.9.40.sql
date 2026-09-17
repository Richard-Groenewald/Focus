-- Focus v7.9.40 — the six performance migrations for PROD in one paste
-- (2026-09-10). Same files as Dev, in the same order, unchanged:
--   1. perf_tier1_indexes.sql   2. perf_tier1_triggers.sql   3. perf_tier1_audit_statement_level.sql
--   4. perf_tier1_sweeps_heartbeat.sql   5. perf_tier2_dashboard_summary.sql   6. perf_tier2_engagements_labelled.sql
-- Each part is its own BEGIN … COMMIT. Run in Supabase → SQL Editor on the prod
-- project (kevrfdjqyuhmgziqxuvs) as one script; NOTICEs appear in the editor's
-- output. The final SELECT summarises what is now installed. Idempotent.
-- Pre-flight on prod (2026-09-10 21:2x UTC): 0 duplicate open affiliations,
-- 0 duplicate usernames, every column and table the files need is present.


-- ════════════════════════════════════════════════════════════════════════
-- sql/perf_tier1_indexes.sql
-- ════════════════════════════════════════════════════════════════════════
-- Focus v7.9.37 — performance Tier 1, part 1: indexes (2026-09-10).
-- Reconciled with sql/add_perf_indexes.sql (July 2026) and the later migrations
-- (add_sites, add_engagement_streams, add_engagement_milestones,
-- add_person_affiliation_and_deal_contacts): every statement is IF NOT EXISTS
-- and the July names are reused, so this is a no-op where those already ran
-- (Dev) and creates them where they did not (prod, if the July file never ran).
-- Plain CREATE INDEX (not CONCURRENTLY): the tables are small, the locks last
-- milliseconds, and the Supabase SQL editor runs a script inside one
-- transaction where CONCURRENTLY is not allowed. Idempotent — safe to re-run.
-- Run on Dev first, then include in the prod release.
-- Full rationale: docs/perf-review/PERFORMANCE_REVIEW.md (Tier 1.1) and the
-- IDX-* entries of docs/perf-review/findings-catalogue.md.

BEGIN;

-- ── July 2026 set (idempotent re-statement so prod cannot miss it) ──────────
CREATE INDEX IF NOT EXISTS idx_engagements_next_action   ON public.engagements (next_action_done, next_action_date);
CREATE INDEX IF NOT EXISTS idx_deals_org                 ON public.deals (org_id);
CREATE INDEX IF NOT EXISTS idx_deals_stage               ON public.deals (stage_id);
CREATE INDEX IF NOT EXISTS idx_deals_owner               ON public.deals (owner_id);
CREATE INDEX IF NOT EXISTS idx_por_org                   ON public.person_organisation_roles (org_id);
CREATE INDEX IF NOT EXISTS idx_lead_red_flags_lead       ON public.lead_red_flags (lead_id);
CREATE INDEX IF NOT EXISTS idx_deal_collaborators_person ON public.deal_collaborators (person_id);
CREATE INDEX IF NOT EXISTS idx_engagement_people_person  ON public.engagement_people (person_id);

-- ── engagements (the largest business table) ─────────────────────────────────
-- Per-lead and per-deal history in the order the pages ask for it. These
-- composites supersede the single-column idx_engagements_lead (unify_engagements)
-- and idx_engagements_deal (July): a leading column serves every eq/in lookup and
-- the FK cascades, the trailing columns return the rows already ordered.
CREATE INDEX IF NOT EXISTS engagements_lead_date_idx
  ON public.engagements (lead_id, engagement_date DESC, id DESC)
  WHERE lead_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS engagements_deal_date_idx
  ON public.engagements (deal_id, engagement_date DESC, id DESC)
  WHERE deal_id IS NOT NULL;
DROP INDEX IF EXISTS public.idx_engagements_lead;
DROP INDEX IF EXISTS public.idx_engagements_deal;

-- Engagement History, the Interactions widget and the Activity report: date
-- ranges and top-N by date over the whole table.
CREATE INDEX IF NOT EXISTS engagements_date_id_idx
  ON public.engagements (engagement_date, id);

-- refresh_lead_next_action's probe (per lead, open actions by due date) — fires
-- on every engagement write.
CREATE INDEX IF NOT EXISTS engagements_lead_open_action_idx
  ON public.engagements (lead_id, next_action_date, id DESC)
  WHERE next_action_done = false AND next_action IS NOT NULL AND next_action_date IS NOT NULL;

-- Group touches (_loadOrgTouches) and the org-chain history on lead open.
CREATE INDEX IF NOT EXISTS engagements_org_date_idx
  ON public.engagements (org_id, engagement_date DESC)
  WHERE org_id IS NOT NULL;

-- Internal Activity page.
CREATE INDEX IF NOT EXISTS engagements_work_project_idx
  ON public.engagements (work_project_id)
  WHERE work_project_id IS NOT NULL;

-- Self-referencing FK (ON DELETE SET NULL): without it every engagement delete
-- scans the whole table. stream_id already has idx_engagements_stream_id.
CREATE INDEX IF NOT EXISTS engagements_related_interaction_idx
  ON public.engagements (related_interaction_id)
  WHERE related_interaction_id IS NOT NULL;

-- ── leads ─────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS leads_promoted_deal_idx ON public.leads (promoted_deal_id) WHERE promoted_deal_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS leads_target_org_idx    ON public.leads (target_org_id)    WHERE target_org_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS leads_source_org_idx    ON public.leads (source_org_id)    WHERE source_org_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS leads_site_idx          ON public.leads (site_id);          -- add_sites.sql name
-- orgs_link_freetext_leads trigger probe (fires on every organisation insert /
-- rename): only the still-unlinked free-text leads, matched by the same expression.
CREATE INDEX IF NOT EXISTS leads_unlinked_org_name_idx
  ON public.leads (lower(trim(target_org_name)))
  WHERE target_org_id IS NULL AND target_org_name IS NOT NULL;

-- ── deals / organisations / sites ─────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS deals_site_idx ON public.deals (site_id);               -- add_sites.sql name
CREATE INDEX IF NOT EXISTS organisations_parent_org_idx
  ON public.organisations (parent_org_id) WHERE parent_org_id IS NOT NULL;
DO $$ BEGIN
  IF to_regclass('public.sites') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS sites_org_idx ON public.sites (organisation_id);   -- add_sites.sql name
  END IF;
END $$;

-- ── person_organisation_roles: one OPEN affiliation per (org, person) ─────────
-- Lets the client drop its duplicate pre-check and rely on a 409 from the POST.
-- Created only when the data already satisfies it; otherwise a NOTICE names the
-- duplicates to clean up first.
DO $$
DECLARE v_dups int;
BEGIN
  SELECT count(*) INTO v_dups FROM (
    SELECT org_id, person_id FROM public.person_organisation_roles
     WHERE end_date IS NULL GROUP BY org_id, person_id HAVING count(*) > 1) d;
  IF v_dups = 0 THEN
    CREATE UNIQUE INDEX IF NOT EXISTS person_organisation_roles_open_uidx
      ON public.person_organisation_roles (org_id, person_id) WHERE end_date IS NULL;
  ELSE
    RAISE NOTICE 'person_organisation_roles_open_uidx skipped: % (org, person) pairs have more than one open affiliation', v_dups;
  END IF;
END $$;

-- ── audit_log: replace, do not add (every business write maintains these) ────
-- The admin viewer orders by (at desc, id desc) and filters by table / actor;
-- composites make each page a bounded index walk instead of a sort.
CREATE INDEX IF NOT EXISTS audit_log_at_id_idx    ON public.audit_log (at DESC, id DESC);
CREATE INDEX IF NOT EXISTS audit_log_table_at_idx ON public.audit_log (table_name, at DESC, id DESC);
CREATE INDEX IF NOT EXISTS audit_log_actor_at_idx ON public.audit_log (actor_id, at DESC, id DESC);
DROP INDEX IF EXISTS public.audit_log_at_idx;
DROP INDEX IF EXISTS public.audit_log_actor_idx;
-- keep audit_log_row_idx (table_name, row_id) and idx_audit_real_actor.

-- ── system_users: case-insensitive uniqueness behind the ilike login lookup ──
DO $$
DECLARE v_dups int;
BEGIN
  SELECT count(*) INTO v_dups FROM (
    SELECT lower(username) FROM public.system_users WHERE username IS NOT NULL
     GROUP BY lower(username) HAVING count(*) > 1) d;
  IF v_dups = 0 THEN
    CREATE UNIQUE INDEX IF NOT EXISTS system_users_username_lower_uidx ON public.system_users (lower(username));
  ELSE
    RAISE NOTICE 'system_users_username_lower_uidx skipped: % usernames differ only by case', v_dups;
  END IF;
END $$;

-- ── Tables from later migrations (guarded: they may not exist on every DB) ───
DO $$ BEGIN
  IF to_regclass('public.deal_contacts') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS deal_contacts_deal_idx   ON public.deal_contacts (deal_id);
    CREATE INDEX IF NOT EXISTS deal_contacts_person_idx ON public.deal_contacts (person_id);
  END IF;
  IF to_regclass('public.engagement_milestones') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS idx_eng_milestones_eng     ON public.engagement_milestones (engagement_id);
    CREATE INDEX IF NOT EXISTS idx_eng_milestones_pending ON public.engagement_milestones (status) WHERE status = 'pending';
  END IF;
  IF to_regclass('public.engagement_people') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'engagement_people'
                       AND indexdef ~ '\(engagement_id') THEN
    CREATE INDEX IF NOT EXISTS engagement_people_engagement_idx ON public.engagement_people (engagement_id);
  END IF;
  IF to_regclass('public.lead_stage_requests') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS lead_stage_requests_lead_idx    ON public.lead_stage_requests (lead_id, requested_at DESC);
    CREATE INDEX IF NOT EXISTS lead_stage_requests_pending_idx ON public.lead_stage_requests (request_type) WHERE status = 'pending';
  END IF;
  IF to_regclass('public.sales_campaign_organisations') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS sales_campaign_organisations_org_idx ON public.sales_campaign_organisations (organisation_id);
  END IF;
END $$;

-- ── Planner statistics ───────────────────────────────────────────────────────
ANALYZE public.engagements;
ANALYZE public.leads;
ANALYZE public.deals;
ANALYZE public.organisations;
ANALYZE public.person_organisation_roles;
ANALYZE public.audit_log;

COMMIT;

-- ── Optional: indexes no query in the app uses (write cost only) ─────────────
-- Uncomment after confirming nothing outside the app (psql, reporting) filters
-- leads by status / next_action_date or deals by opportunity_type alone.
-- DROP INDEX IF EXISTS public.idx_leads_next_action_date;
-- DROP INDEX IF EXISTS public.idx_leads_status;
-- DROP INDEX IF EXISTS public.deals_opportunity_type_idx;

-- Verify:
--   SELECT tablename, indexname FROM pg_indexes WHERE schemaname = 'public'
--    AND tablename IN ('engagements','leads','deals','audit_log','person_organisation_roles') ORDER BY 1, 2;
-- After a week, anything with idx_scan = 0 on a business table is a drop candidate:
--   SELECT relname, indexrelname, idx_scan FROM pg_stat_user_indexes WHERE schemaname = 'public' ORDER BY idx_scan, relname;

-- ════════════════════════════════════════════════════════════════════════
-- sql/perf_tier1_triggers.sql
-- ════════════════════════════════════════════════════════════════════════
-- Focus v7.9.37 — performance Tier 1, part 2: engagement / organisation triggers
-- (2026-09-10). Idempotent. Run on Dev first, then prod. Rationale: Tier 1.2 and
-- 1.3 in docs/perf-review/PERFORMANCE_REVIEW.md (findings TRG-A2, TRG-1, TRG-A5).
--
-- Before running, list what the database actually has so nothing here surprises you:
--   SELECT tgrelid::regclass, tgname, pg_get_triggerdef(oid)
--     FROM pg_trigger WHERE NOT tgisinternal ORDER BY 1, 2;

BEGIN;

-- ── 1.2  refresh_lead_next_action: fire only when the relevant columns change,
--        and only rewrite the leads row when the derived values actually differ.
--        sql/unify_engagements.sql made it fire on EVERY engagement write and do
--        an unconditional UPDATE leads (new tuple, audit diff, stage-event trigger)
--        even when nothing changed — three lead rewrites per engagement logged.
--        Same SELECT, same result; the trigger function trg_engagements_refresh_next_action
--        is unchanged.
CREATE OR REPLACE FUNCTION public.refresh_lead_next_action(p_lead_id bigint) RETURNS void
    LANGUAGE plpgsql AS $$
DECLARE
  v_next_action      TEXT;
  v_next_action_date DATE;
BEGIN
  IF p_lead_id IS NULL THEN RETURN; END IF;

  SELECT next_action, next_action_date
    INTO v_next_action, v_next_action_date
  FROM public.engagements
  WHERE lead_id          = p_lead_id
    AND next_action_done = false
    AND next_action      IS NOT NULL
    AND next_action_date IS NOT NULL
  ORDER BY next_action_date ASC, id DESC
  LIMIT 1;

  UPDATE public.leads
     SET next_action = v_next_action, next_action_date = v_next_action_date, updated_at = now()
   WHERE id = p_lead_id
     AND (next_action IS DISTINCT FROM v_next_action
          OR next_action_date IS DISTINCT FROM v_next_action_date);
END;
$$;

DROP TRIGGER IF EXISTS engagements_refresh_next_action ON public.engagements;
CREATE TRIGGER engagements_refresh_next_action
  AFTER INSERT OR DELETE OR UPDATE OF lead_id, next_action, next_action_date, next_action_done
  ON public.engagements
  FOR EACH ROW EXECUTE FUNCTION public.trg_engagements_refresh_next_action();

-- ── 1.3  Default stream_id to the row's own id (a new engagement is the root of
--        its own stream) so the app no longer needs a second write to the row it
--        just inserted. Identity/serial defaults are applied before BEFORE ROW
--        triggers, so NEW.id is available. The self-referencing FK
--        (add_engagement_streams.sql) is satisfied by the row itself.
--        The app (v7.9.37) sends stream_label in the INSERT and only PATCHes
--        stream_id when the returned row still has none — i.e. on a database
--        where this trigger has not been installed.
CREATE OR REPLACE FUNCTION public.engagements_default_stream() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.stream_id IS NULL THEN NEW.stream_id := NEW.id; END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS engagements_default_stream ON public.engagements;
CREATE TRIGGER engagements_default_stream
  BEFORE INSERT ON public.engagements
  FOR EACH ROW EXECUTE FUNCTION public.engagements_default_stream();

-- ── TRG-A5  orgs_link_freetext_leads: fire only when a name actually changed.
--        The trigger function (schema.sql trg_orgs_link_freetext_leads) scans
--        leads by lower(trim(target_org_name)); perf_tier1_indexes.sql adds the
--        matching expression index. A WHEN clause cannot reference OLD on INSERT,
--        hence one trigger per event.
DROP TRIGGER IF EXISTS orgs_link_freetext_leads ON public.organisations;
DROP TRIGGER IF EXISTS orgs_link_freetext_leads_ins ON public.organisations;
DROP TRIGGER IF EXISTS orgs_link_freetext_leads_upd ON public.organisations;
CREATE TRIGGER orgs_link_freetext_leads_ins
  AFTER INSERT ON public.organisations
  FOR EACH ROW EXECUTE FUNCTION public.trg_orgs_link_freetext_leads();
CREATE TRIGGER orgs_link_freetext_leads_upd
  AFTER UPDATE OF name, legal_name ON public.organisations
  FOR EACH ROW
  WHEN (NEW.name IS DISTINCT FROM OLD.name OR NEW.legal_name IS DISTINCT FROM OLD.legal_name)
  EXECUTE FUNCTION public.trg_orgs_link_freetext_leads();

COMMIT;

-- Verify (Dev): log an engagement on a lead and check
--   SELECT stream_id, id FROM engagements ORDER BY id DESC LIMIT 1;   -- stream_id = id
--   SELECT count(*) FROM audit_log WHERE table_name = 'leads' AND at > now() - interval '1 minute';
--   -- one leads row change per engagement, not three

-- ════════════════════════════════════════════════════════════════════════
-- sql/perf_tier1_audit_statement_level.sql
-- ════════════════════════════════════════════════════════════════════════
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

-- ════════════════════════════════════════════════════════════════════════
-- sql/perf_tier1_sweeps_heartbeat.sql
-- ════════════════════════════════════════════════════════════════════════
-- Focus v7.9.37 — performance Tier 1, part 4: sweep_leads() and heartbeat()
-- (2026-09-10). Rationale: Tier 1.5 / 2.9 / 2.13 in docs/perf-review/PERFORMANCE_REVIEW.md
-- (findings TRG-A3, LR-02, ATT-2, POLL-1).
--
-- The app calls both through the existing proxy:
--   api('rpc/sweep_leads', 'POST', { p_flip: true })   -> /rest/v1/rpc/sweep_leads
--   api('rpc/heartbeat',   'POST', { p_person_id, p_version })
-- and falls back to its previous behaviour (per-lead PATCHes / PATCH + GET) when a
-- function is absent, so this file can be run before or after the v7.9.37 deploy.
-- Idempotent. Run on Dev first, then prod.

BEGIN;

-- ── heartbeat: presence upsert + live broadcasts in ONE call ─────────────────
-- Replaces PATCH user_presence (+ POST fallback) + GET broadcasts per tick.
-- user_presence.person_id is the primary key (add_broadcasts.sql).
CREATE OR REPLACE FUNCTION public.heartbeat(p_person_id bigint, p_version text)
RETURNS SETOF public.broadcasts
LANGUAGE sql SECURITY DEFINER AS $$
  INSERT INTO public.user_presence (person_id, last_seen_at, app_version)
  VALUES (p_person_id, now(), p_version)
  ON CONFLICT (person_id) DO UPDATE
    SET last_seen_at = excluded.last_seen_at, app_version = excluded.app_version;
  SELECT * FROM public.broadcasts
   WHERE ended_at IS NULL AND expires_at > now()
   ORDER BY created_at DESC;
$$;

-- ── sweep_leads: the New→Working flip and the Hold wake as two set-based
--    statements. Mirrors index.html: sweepNewToWorking, sweepHoldWake,
--    computeLeadStatus and the lead*Complete helpers (v7.9.36). Until now the
--    browser PATCHed one lead per round trip on every register, cockpit and
--    dashboard load. Keep these rules and the JS in step.
--    Returns the changed rows so the page can patch its in-memory list:
--      { "working": [{id, status, working_at}], "woke": [{id, status, working_at, woke_at, wake_date}] }

-- leadNameHasTwoParts: first + last name present.
CREATE OR REPLACE FUNCTION public.lead_name_has_two_parts(s text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(array_length(array_remove(regexp_split_to_array(trim(coalesce(s, '')), '\s+'), ''), 1), 0) >= 2
$$;

-- leadHasPhone: at least 7 digits.
CREATE OR REPLACE FUNCTION public.lead_has_phone(p text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT length(regexp_replace(coalesce(p, ''), '\D', '', 'g')) >= 7
$$;

-- leadSourceComplete
CREATE OR REPLACE FUNCTION public.lead_source_complete(l public.leads) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT CASE s.name
    WHEN 'Referral' THEN l.source_person_id IS NOT NULL
         OR (public.lead_name_has_two_parts(l.source_person_name)
             AND (nullif(trim(l.source_person_email), '') IS NOT NULL OR public.lead_has_phone(l.source_person_phone)))
    WHEN 'Client Expansion'   THEN l.source_org_id IS NOT NULL
    WHEN 'Marketing Campaign' THEN l.research_campaign_id IS NOT NULL
    WHEN 'Research Campaign'  THEN l.research_campaign_id IS NOT NULL
    WHEN 'Research'           THEN l.research_campaign_id IS NOT NULL
    WHEN 'Research Study'     THEN l.sales_campaign_id IS NOT NULL
    WHEN 'Sales Campaign'     THEN l.sales_campaign_id IS NOT NULL
    ELSE nullif(trim(l.source_detail), '') IS NOT NULL END
  FROM public.lead_sources s
  WHERE s.id = l.source_id
$$;

-- leadWorkingPrereqsMet(l, null) = source complete AND description AND target contact
CREATE OR REPLACE FUNCTION public.lead_working_prereqs(l public.leads) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT coalesce(public.lead_source_complete(l), false)
     AND nullif(trim(l.description), '') IS NOT NULL
     AND (l.target_person_id IS NOT NULL
          OR (public.lead_name_has_two_parts(l.target_person_name)
              AND (nullif(trim(l.target_person_email), '') IS NOT NULL OR public.lead_has_phone(l.target_person_phone))))
$$;

CREATE OR REPLACE FUNCTION public.sweep_leads(p_flip boolean DEFAULT true) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_grace   int;
  v_working jsonb := '[]'::jsonb;
  v_woke    jsonb := '[]'::jsonb;
BEGIN
  -- new_lead_waiting_minutes: the editable grace after a lead becomes Working.
  SELECT coalesce(nullif(trim(value), '')::int, 0) INTO v_grace
    FROM public.settings WHERE key = 'new_lead_waiting_minutes';
  v_grace := coalesce(v_grace, 0);

  -- New → Working (sweepNewToWorking): mandatory fields + a next step + a first engagement.
  IF p_flip THEN
    WITH f AS (
      UPDATE public.leads l
         SET status = 'Working', working_at = coalesce(l.working_at, now()), updated_at = now()
       WHERE l.status = 'New' AND l.dead_reason IS NULL AND l.wake_date IS NULL AND l.promoted_at IS NULL
         AND l.first_engaged_at IS NOT NULL
         AND l.next_action IS NOT NULL AND l.next_action_date IS NOT NULL
         AND public.lead_working_prereqs(l)
      RETURNING l.id, l.status, l.working_at)
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'status', status, 'working_at', working_at)), '[]'::jsonb)
      INTO v_working FROM f;
  END IF;

  -- Hold → awake (sweepHoldWake): wake date reached. Landing stage per computeLeadStatus
  -- with wake_date cleared and working_at = existing or now.
  WITH w AS (
    UPDATE public.leads l
       SET wake_date  = NULL,
           woke_at    = now(),
           working_at = coalesce(l.working_at, now()),
           updated_at = now(),
           status = CASE
             WHEN l.fit = 2 AND l.trigger_score = 2 AND l.access = 2 AND l.capacity = 2
                  AND l.service_major_id IS NOT NULL AND l.service_major_id > 0
                  AND (l.target_org_id IS NOT NULL OR nullif(trim(l.target_org_name), '') IS NOT NULL)
                  AND coalesce(l.qualification_demoted, false) = false                    THEN 'Qualified'
             WHEN now() - coalesce(l.working_at, now()) >= make_interval(mins => v_grace) THEN 'Working'
             WHEN public.lead_working_prereqs(l) AND l.next_action IS NOT NULL
                  AND l.next_action_date IS NOT NULL AND l.first_engaged_at IS NOT NULL   THEN 'Working'
             ELSE 'New' END
     WHERE l.status = 'Hold' AND l.wake_date IS NOT NULL AND l.wake_date <= current_date
       AND l.promoted_at IS NULL AND l.dead_reason IS NULL
    RETURNING l.id, l.status, l.working_at, l.woke_at, l.wake_date)
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'status', status, 'working_at', working_at,
                                               'woke_at', woke_at, 'wake_date', wake_date)), '[]'::jsonb)
    INTO v_woke FROM w;

  RETURN jsonb_build_object('working', v_working, 'woke', v_woke);
END;
$$;

COMMIT;

-- Verify (Dev):
--   SELECT public.sweep_leads(false);   -- wake only: {"working": [], "woke": [...]}
--   SELECT public.sweep_leads();        -- both
--   SELECT * FROM public.heartbeat(<your person id>, 'test');   -- returns live broadcasts; user_presence row updated
--
-- Optional: run the sweep on a schedule as well, so leads flip even when nobody
-- opens the register (pg_cron is available on Supabase):
--   CREATE EXTENSION IF NOT EXISTS pg_cron;
--   SELECT cron.schedule('focus_sweep_leads', '*/10 * * * *', $$SELECT public.sweep_leads()$$);

-- ════════════════════════════════════════════════════════════════════════
-- sql/perf_tier2_dashboard_summary.sql
-- ════════════════════════════════════════════════════════════════════════
-- Focus v7.9.38 — performance Tier 2, part 1: dashboard_summary()
-- (2026-09-10). Rationale: Tier 2.3 in docs/perf-review/PERFORMANCE_REVIEW.md
-- (findings D2, D3, D4, D5, D6, D11).
--
-- The dashboard used to issue ~30 requests per render: leads whole-table four
-- times, deals five times, engagements three times, plus serial 150-id chunk
-- loops for milestones. This returns every dataset the thirteen widgets read in
-- ONE call. The widgets keep their own counting and the Mine / Team / All scope
-- rule (rows carry owner_id, branch_id, region_id), so the numbers are computed
-- exactly as before — only the round trips change.
--
-- The app calls it through the existing proxy:
--   api('rpc/dashboard_summary', 'POST', { p_from: 'YYYY-MM-DD' })
-- and falls back to the per-widget reads when the function is absent
-- (404 / PGRST202), so this file can ship before or after the v7.9.38 deploy.
-- Idempotent. Run on Dev first, then prod.
--
-- Keys returned (all arrays unless noted):
--   leads            every lead, the union of the columns the four widgets read,
--                    with sites:{name} in the PostgREST embed shape
--   deals            id, name, stage_id, probability, owner/branch/region, org_id, service_sub_id
--   orgs             id, parent_org_id, group_touch_soothes, sector_id
--   org_touches      object {"o<org_id>": "YYYY-MM-DD"} — latest non-internal touch (_loadOrgTouches)
--   open_actions     engagements with an open, dated next action
--   promotion_requests / stage_requests   pending rows for Approvals Outstanding
--   pending_milestones (≤100, oldest first) / approved_milestones (≤80, newest decided first)
--                    engagement_milestones rows plus _lead_id, _deal_id, _deal_name / _engagement_date
--   pulse_milestones every pending row plus approved rows dated this month or last month
--   milestone_groups, milestone_types, red_flags, pending_red_flags, campaigns, bugs (≤500),
--   industry_sectors, stages
--   stream_values    per deal: opp_total (opportunity streams' opportunity_revenue),
--                    sec_total (fulfilment streams' secured_revenue) — from revenue streams only
--   interactions     engagements dated >= p_from with _owner_id (parent's owner) and _cat
--                    (Outreach / Sales / Contract / Project — the _engHistCat rule)

BEGIN;

CREATE OR REPLACE FUNCTION public.dashboard_summary(
  p_from date DEFAULT (date_trunc('month', now()) - interval '11 months')::date)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
SELECT jsonb_build_object(
  'generated_at', now(),

  'leads', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', l.id, 'owner_id', l.owner_id, 'branch_id', l.branch_id, 'region_id', l.region_id, 'status', l.status,
      'wake_date', l.wake_date, 'woke_at', l.woke_at, 'created_at', l.created_at, 'last_touch_date', l.last_touch_date,
      'promoted_at', l.promoted_at, 'dead_reason', l.dead_reason, 'working_at', l.working_at,
      'fit', l.fit, 'access', l.access, 'capacity', l.capacity, 'trigger_score', l.trigger_score,
      'service_major_id', l.service_major_id, 'qualification_demoted', l.qualification_demoted,
      'target_org_name', l.target_org_name, 'target_org_id', l.target_org_id, 'description', l.description,
      'site_id', l.site_id, 'site_name', l.site_name, 'next_action_date', l.next_action_date,
      'sites', CASE WHEN s.id IS NULL THEN NULL ELSE jsonb_build_object('name', s.name) END) ORDER BY l.id), '[]'::jsonb)
    FROM public.leads l LEFT JOIN public.sites s ON s.id = l.site_id),

  'deals', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', d.id, 'name', d.name, 'stage_id', d.stage_id, 'probability', d.probability,
      'owner_id', d.owner_id, 'branch_id', d.branch_id, 'region_id', d.region_id,
      'org_id', d.org_id, 'service_sub_id', d.service_sub_id) ORDER BY d.id), '[]'::jsonb)
    FROM public.deals d),

  'orgs', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', o.id, 'parent_org_id', o.parent_org_id, 'group_touch_soothes', o.group_touch_soothes,
      'sector_id', o.sector_id) ORDER BY o.id), '[]'::jsonb)
    FROM public.organisations o),

  'org_touches', (SELECT coalesce(jsonb_object_agg('o' || t.org_id, t.last_touch), '{}'::jsonb)
    FROM (SELECT org_id, max(engagement_date) AS last_touch
            FROM public.engagements
           WHERE org_id IS NOT NULL AND engagement_date IS NOT NULL AND work_mode IS DISTINCT FROM 'internal'
           GROUP BY org_id) t),

  'open_actions', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'lead_id', e.lead_id, 'deal_id', e.deal_id, 'next_action', e.next_action,
      'next_action_date', e.next_action_date, 'engagement_type', e.engagement_type,
      'stream_id', e.stream_id, 'engagement_date', e.engagement_date) ORDER BY e.id), '[]'::jsonb)
    FROM public.engagements e
   WHERE e.next_action_done = false AND e.next_action_date IS NOT NULL),

  'promotion_requests', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'lead_id', r.lead_id, 'request_type', r.request_type, 'requested_by', r.requested_by,
      'requested_at', r.requested_at) ORDER BY r.id), '[]'::jsonb)
    FROM public.promotion_requests r WHERE r.status = 'pending'),

  'stage_requests', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'lead_id', r.lead_id, 'request_type', r.request_type, 'requested_by', r.requested_by,
      'requested_at', r.requested_at) ORDER BY r.id), '[]'::jsonb)
    FROM public.lead_stage_requests r WHERE r.status = 'pending' AND r.request_type = 'dead'),

  'pending_milestones', (SELECT coalesce(jsonb_agg(
      to_jsonb(m) || jsonb_build_object('_lead_id', e.lead_id, '_deal_id', e.deal_id, '_deal_name', d.name)
      ORDER BY m.proposed_at ASC, m.id), '[]'::jsonb)
    FROM (SELECT * FROM public.engagement_milestones WHERE status = 'pending'
           ORDER BY proposed_at ASC, id LIMIT 100) m
    JOIN public.engagements e ON e.id = m.engagement_id
    LEFT JOIN public.deals d ON d.id = e.deal_id),

  'approved_milestones', (SELECT coalesce(jsonb_agg(
      to_jsonb(m) || jsonb_build_object('_lead_id', e.lead_id, '_deal_id', e.deal_id, '_engagement_date', e.engagement_date)
      ORDER BY m.decided_at DESC NULLS LAST, m.id DESC), '[]'::jsonb)
    FROM (SELECT * FROM public.engagement_milestones WHERE status = 'approved'
           ORDER BY decided_at DESC NULLS LAST, id DESC LIMIT 80) m
    JOIN public.engagements e ON e.id = m.engagement_id),

  'pulse_milestones', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', m.id, 'engagement_id', m.engagement_id, 'milestone_type_id', m.milestone_type_id,
      'status', m.status, 'decided_at', m.decided_at,
      '_lead_id', e.lead_id, '_deal_id', e.deal_id, '_engagement_date', e.engagement_date) ORDER BY m.id), '[]'::jsonb)
    FROM public.engagement_milestones m
    JOIN public.engagements e ON e.id = m.engagement_id
   WHERE m.status = 'pending'
      OR (m.status = 'approved'
          AND coalesce(e.engagement_date, m.decided_at::date) >= (date_trunc('month', now()) - interval '1 month')::date)),

  'milestone_groups', (SELECT coalesce(jsonb_agg(to_jsonb(g) ORDER BY g.sort_order, g.id), '[]'::jsonb) FROM public.milestone_groups g),
  'milestone_types',  (SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.sort_order, t.id), '[]'::jsonb) FROM public.milestone_types t),

  'red_flags', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'name', f.name) ORDER BY f.sort_order, f.id), '[]'::jsonb)
    FROM public.red_flags f),
  'pending_red_flags', (SELECT coalesce(jsonb_agg(jsonb_build_object('lead_id', x.lead_id, 'red_flag_id', x.red_flag_id)), '[]'::jsonb)
    FROM public.lead_red_flags x WHERE x.review_status = 'pending' AND x.cleared = false),

  'campaigns', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', c.id, 'name', c.name, 'status', c.status, 'owner_id', c.owner_id, 'created_by', c.created_by) ORDER BY c.id), '[]'::jsonb)
    FROM public.research_campaigns c),

  'bugs', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', b.id, 'severity', b.severity, 'status', b.status, 'description', left(b.description, 300),
      'page', b.page, 'created_at', b.created_at) ORDER BY b.created_at DESC, b.id DESC), '[]'::jsonb)
    FROM (SELECT * FROM public.bug_reports ORDER BY created_at DESC, id DESC LIMIT 500) b),

  -- Financials come from revenue streams only (never base amount / num months).
  'stream_values', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'deal_id', v.deal_id, 'opp_total', v.opp_total, 'sec_total', v.sec_total) ORDER BY v.deal_id), '[]'::jsonb)
    FROM (SELECT rs.deal_id,
                 sum(CASE WHEN rs.stream_type = 'opportunity' THEN coalesce(m.opportunity_revenue, 0) ELSE 0 END) AS opp_total,
                 sum(CASE WHEN rs.stream_type = 'fulfilment'  THEN coalesce(m.secured_revenue, 0)     ELSE 0 END) AS sec_total
            FROM public.revenue_streams rs
            JOIN public.revenue_stream_months m ON m.stream_id = rs.id
           GROUP BY rs.deal_id) v),

  'interactions', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'lead_id', e.lead_id, 'deal_id', e.deal_id, 'engagement_date', e.engagement_date,
      'engagement_type', e.engagement_type, 'created_by', e.created_by,
      '_owner_id', coalesce(l.owner_id, d.owner_id),
      '_cat', CASE WHEN e.lead_id IS NOT NULL THEN 'Outreach'
                   WHEN d.stage_id IN (5, 7, 8) THEN CASE WHEN ss.is_recurring = false THEN 'Project' ELSE 'Contract' END
                   ELSE 'Sales' END) ORDER BY e.engagement_date, e.id), '[]'::jsonb)
    FROM public.engagements e
    LEFT JOIN public.leads l        ON l.id = e.lead_id
    LEFT JOIN public.deals d        ON d.id = e.deal_id
    LEFT JOIN public.service_sub ss ON ss.id = d.service_sub_id
   WHERE e.engagement_date >= p_from),

  'industry_sectors', (SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.id), '[]'::jsonb) FROM public.industry_sectors s),
  'stages', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) ORDER BY s.id), '[]'::jsonb) FROM public.stages s)
);
$$;

COMMIT;

-- Verify (Dev):
--   SELECT length(public.dashboard_summary()::text) AS bytes;           -- payload size, uncompressed
--   SELECT k, jsonb_typeof(v) AS t, CASE WHEN jsonb_typeof(v) = 'array' THEN jsonb_array_length(v) END AS n
--     FROM jsonb_each(public.dashboard_summary()) AS x(k, v) ORDER BY k;
--   SELECT public.dashboard_summary('2026-08-01') -> 'interactions' -> 0;

-- ════════════════════════════════════════════════════════════════════════
-- sql/perf_tier2_engagements_labelled.sql
-- ════════════════════════════════════════════════════════════════════════
-- Focus v7.9.38 — performance Tier 2, part 2: engagements_labelled view
-- (2026-09-10). Rationale: Tier 2.6 in docs/perf-review/PERFORMANCE_REVIEW.md
-- (findings EH-1, RPT-1, MIL-1, ATT-1, IA-1, D9).
--
-- Engagement History resolved every label in the browser: the engagement rows,
-- then deals + leads + engagement_people + milestones + stream roots, then
-- people + organisations — three dependent rounds per open and per date or
-- category change. This view carries every one of those labels on the row, so
-- the page reads it in ONE call with the same filters it already sends:
--   apiGet('engagements_labelled', 'lead_id=not.is.null&engagement_date=gte.…&select=*&order=engagement_date.desc,id.desc&limit=1000')
-- The client (v7.9.38) falls back to the old reads when the view is absent
-- (404 / PGRST205), so this file can ship before or after the deploy.
-- Plain view (no data copied, nothing to refresh). Idempotent. Dev first, then prod.
--
-- Label rules mirror index.html exactly (keep them in step):
--   cat / lost              _engHistCat: lead → Outreach; stage 6 → Sales + lost;
--                           stages 5/7/8 → Project when service_sub.is_recurring = false else Contract;
--                           anything else → Sales; no parent → NULL (the page drops such rows)
--   stream_root             stream_id, else the row's own id
--   stream_label_resolved   the ROOT row's stream_label (NULL → the page shows "Stream #<root>")
--   client_name             lead: org name by target_org_id, else target_org_name; deal: org name — else "—"
--   parent_label            lead: leadEngLabel — site name, site_name, target_org_name, description, "Lead #n";
--                           deal: name, "Deal #n"
--   owner_id / owner_name   the parent's owner; "Person #n" when the people row is missing; "—" when none
--   persons                 engagement_people names; a lead engagement with none falls back to the
--                           lead's target person (by id, else the typed name)
--   milestones              every engagement_milestones row for the engagement (badges)

BEGIN;

CREATE OR REPLACE VIEW public.engagements_labelled AS
SELECT e.*,
       CASE WHEN e.lead_id IS NOT NULL THEN 'lead' WHEN e.deal_id IS NOT NULL THEN 'deal' END AS parent_kind,
       coalesce(e.lead_id, e.deal_id)                                              AS parent_id,
       CASE WHEN e.lead_id IS NOT NULL THEN 'Outreach'
            WHEN d.id IS NULL THEN NULL
            WHEN d.stage_id = 6 THEN 'Sales'
            WHEN d.stage_id IN (5, 7, 8) THEN CASE WHEN ss.is_recurring = false THEN 'Project' ELSE 'Contract' END
            ELSE 'Sales' END                                                       AS cat,
       (e.lead_id IS NULL AND d.stage_id = 6)                                      AS lost,
       coalesce(e.stream_id, e.id)                                                 AS stream_root,
       nullif(root.stream_label, '')                                               AS stream_label_resolved,
       CASE WHEN e.lead_id IS NOT NULL THEN coalesce(nullif(o_l.name, ''), nullif(l.target_org_name, ''), '—')
            ELSE coalesce(nullif(o_d.name, ''), '—') END                           AS client_name,
       CASE WHEN e.lead_id IS NOT NULL
            THEN coalesce(nullif(s_l.name, ''), nullif(trim(l.site_name), ''), nullif(l.target_org_name, ''),
                          nullif(l.description, ''), 'Lead #' || e.lead_id)
            ELSE coalesce(nullif(d.name, ''), 'Deal #' || e.deal_id) END           AS parent_label,
       coalesce(l.owner_id, d.owner_id)                                            AS owner_id,
       CASE WHEN coalesce(l.owner_id, d.owner_id) IS NULL THEN '—'
            ELSE coalesce(nullif(trim(concat_ws(' ', p_o.first_name, p_o.last_name)), ''),
                          'Person #' || coalesce(l.owner_id, d.owner_id)) END      AS owner_name,
       coalesce(pp.persons,
                CASE WHEN e.lead_id IS NOT NULL AND l.target_person_id IS NOT NULL
                     THEN jsonb_build_array(coalesce(nullif(trim(concat_ws(' ', p_t.first_name, p_t.last_name)), ''),
                                                     'Person #' || l.target_person_id))
                     WHEN e.lead_id IS NOT NULL AND nullif(l.target_person_name, '') IS NOT NULL
                     THEN jsonb_build_array(l.target_person_name)
                     ELSE '[]'::jsonb END)                                         AS persons,
       coalesce(mm.milestones, '[]'::jsonb)                                        AS milestones
  FROM public.engagements e
  LEFT JOIN public.leads l           ON l.id = e.lead_id
  LEFT JOIN public.sites s_l         ON s_l.id = l.site_id
  LEFT JOIN public.organisations o_l ON o_l.id = l.target_org_id
  LEFT JOIN public.people p_t        ON p_t.id = l.target_person_id
  LEFT JOIN public.deals d           ON d.id = e.deal_id
  LEFT JOIN public.organisations o_d ON o_d.id = d.org_id
  LEFT JOIN public.service_sub ss    ON ss.id = d.service_sub_id
  LEFT JOIN public.people p_o        ON p_o.id = coalesce(l.owner_id, d.owner_id)
  LEFT JOIN public.engagements root  ON root.id = coalesce(e.stream_id, e.id)
  LEFT JOIN LATERAL (
       SELECT jsonb_agg(coalesce(nullif(trim(concat_ws(' ', p.first_name, p.last_name)), ''), 'Person #' || ep.person_id)
                        ORDER BY ep.id) AS persons
         FROM public.engagement_people ep
         LEFT JOIN public.people p ON p.id = ep.person_id
        WHERE ep.engagement_id = e.id) pp ON true
  LEFT JOIN LATERAL (
       SELECT jsonb_agg(to_jsonb(m) ORDER BY m.id) AS milestones
         FROM public.engagement_milestones m
        WHERE m.engagement_id = e.id) mm ON true;

COMMIT;

-- Verify (Dev):
--   SELECT count(*) FROM public.engagements_labelled;                       -- = count(*) FROM engagements
--   SELECT id, cat, lost, stream_root, stream_label_resolved, client_name, parent_label, owner_name, persons, milestones
--     FROM public.engagements_labelled ORDER BY engagement_date DESC, id DESC LIMIT 5;
--   EXPLAIN ANALYZE SELECT * FROM public.engagements_labelled
--     WHERE lead_id IS NOT NULL AND engagement_date >= current_date - 180
--     ORDER BY engagement_date DESC, id DESC LIMIT 1000;                     -- uses engagements_lead_date_idx / engagements_date_id_idx

-- ── Verify: one row summarising the install ──────────────────────────────────
NOTIFY pgrst, 'reload schema';
SELECT
  (SELECT string_agg(proname, ', ' ORDER BY proname) FROM pg_proc
    WHERE pronamespace = 'public'::regnamespace
      AND proname IN ('sweep_leads','heartbeat','audit_stmt','engagements_default_stream','dashboard_summary','lead_working_prereqs'))
    AS functions_installed,                                       -- expect all six
  to_regclass('public.engagements_labelled') IS NOT NULL          AS view_installed,          -- expect true
  (SELECT count(*) FROM pg_indexes WHERE schemaname = 'public'
     AND indexname IN ('engagements_lead_date_idx','engagements_deal_date_idx','engagements_date_id_idx','engagements_lead_open_action_idx',
                       'leads_unlinked_org_name_idx','audit_log_at_id_idx','person_organisation_roles_open_uidx','system_users_username_lower_uidx'))
    AS key_indexes_present,                                       -- expect 8
  (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgname LIKE 'audit_ins_%') AS tables_on_statement_audit,   -- expect ~64
  (SELECT count(*) FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
     WHERE NOT t.tgisinternal AND p.proname = 'audit_row_change')  AS tables_still_row_audit,      -- expect ~10 (no id column)
  (SELECT jsonb_pretty(public.sweep_leads(false)))                 AS wake_sweep_result,            -- {"woke": [...], "working": []}
  (SELECT length(public.dashboard_summary()::text))                AS bundle_bytes;
