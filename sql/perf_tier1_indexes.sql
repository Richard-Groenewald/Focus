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
