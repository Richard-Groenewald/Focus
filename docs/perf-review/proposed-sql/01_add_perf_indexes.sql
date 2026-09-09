-- Focus CRM performance review, September 2026 — proposal 1.1
-- Missing indexes on the hot predicates (see findings IDX-00..IDX-13 in findings-catalogue.md).
--
-- RUN STATEMENT BY STATEMENT in the Supabase SQL editor or psql. Do NOT wrap in
-- BEGIN/COMMIT: CREATE/DROP INDEX CONCURRENTLY cannot run inside a transaction
-- block. Every statement is idempotent. A statement that fails with
-- "column ... does not exist" means that database lacks the out-of-repo
-- migration for that column: skip it there.
--
-- Run on test first, then prod. Afterwards compare:
--   select tablename, indexname, indexdef from pg_indexes
--    where schemaname = 'public'
--      and tablename in ('engagements','leads','deals','audit_log','person_organisation_roles')
--    order by 1, 2;

-- ── engagements (largest business table) ─────────────────────────────────────
-- deal_id=eq / deal_id=in / FK cascade, returned in the order the deal page asks for
CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_deal_date_idx
  ON public.engagements (deal_id, engagement_date DESC, id DESC)
  WHERE deal_id IS NOT NULL;

-- lead_id=eq with the history order; supersedes the single-column idx_engagements_lead
CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_lead_date_idx
  ON public.engagements (lead_id, engagement_date DESC, id DESC)
  WHERE lead_id IS NOT NULL;
DROP INDEX CONCURRENTLY IF EXISTS public.idx_engagements_lead;

-- Engagement History / Interactions widget / Activity report: date ranges and top-N by date
CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_date_id_idx
  ON public.engagements (engagement_date, id);

-- Dashboard "Outstanding actions" and Attention: only the open rows, in due-date order
CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_open_actions_idx
  ON public.engagements (next_action_date, id)
  WHERE next_action_done = false AND next_action_date IS NOT NULL;

-- refresh_lead_next_action trigger probe (per lead, open actions by due date)
CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_lead_open_action_idx
  ON public.engagements (lead_id, next_action_date, id DESC)
  WHERE next_action_done = false AND next_action IS NOT NULL AND next_action_date IS NOT NULL;

-- Group touches (_loadOrgTouches) and the org-chain history on lead open
CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_org_date_idx
  ON public.engagements (org_id, engagement_date DESC)
  WHERE org_id IS NOT NULL;

-- Internal Activity page
CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_work_project_idx
  ON public.engagements (work_project_id)
  WHERE work_project_id IS NOT NULL;

-- Self-referencing FKs: without these every engagement delete scans the whole table
CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_related_interaction_idx
  ON public.engagements (related_interaction_id)
  WHERE related_interaction_id IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_stream_idx
  ON public.engagements (stream_id)
  WHERE stream_id IS NOT NULL;

-- ── leads ─────────────────────────────────────────────────────────────────────
CREATE INDEX CONCURRENTLY IF NOT EXISTS leads_promoted_deal_idx
  ON public.leads (promoted_deal_id) WHERE promoted_deal_id IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS leads_target_org_idx
  ON public.leads (target_org_id) WHERE target_org_id IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS leads_site_idx
  ON public.leads (site_id) WHERE site_id IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS leads_source_org_idx
  ON public.leads (source_org_id) WHERE source_org_id IS NOT NULL;

-- orgs_link_freetext_leads trigger probe (fires on every organisation insert / rename)
CREATE INDEX CONCURRENTLY IF NOT EXISTS leads_unlinked_org_name_idx
  ON public.leads (lower(trim(target_org_name)))
  WHERE target_org_id IS NULL AND target_org_name IS NOT NULL;

-- Never used by a client predicate (status and overdue are computed in the browser);
-- next_action_date is rewritten by refresh_lead_next_action on every engagement write.
DROP INDEX CONCURRENTLY IF EXISTS public.idx_leads_next_action_date;
DROP INDEX CONCURRENTLY IF EXISTS public.idx_leads_status;

-- ── deals / organisations ─────────────────────────────────────────────────────
CREATE INDEX CONCURRENTLY IF NOT EXISTS deals_org_idx   ON public.deals (org_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS deals_owner_idx ON public.deals (owner_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS deals_stage_idx ON public.deals (stage_id);
DROP INDEX CONCURRENTLY IF EXISTS public.deals_opportunity_type_idx;   -- 3 values, only ever used with parent_deal_id
CREATE INDEX CONCURRENTLY IF NOT EXISTS organisations_parent_org_idx
  ON public.organisations (parent_org_id) WHERE parent_org_id IS NOT NULL;

-- ── person_organisation_roles (org_id=eq is the most-issued filtered lookup, 17 sites) ──
CREATE INDEX CONCURRENTLY IF NOT EXISTS person_organisation_roles_org_idx
  ON public.person_organisation_roles (org_id, person_id);
-- One open affiliation per (org, person): lets the client drop its duplicate pre-check
-- and rely on a 409 from the POST instead. Check first:
--   select org_id, person_id, count(*) from person_organisation_roles
--    where end_date is null group by 1,2 having count(*) > 1;
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS person_organisation_roles_open_uidx
  ON public.person_organisation_roles (org_id, person_id) WHERE end_date IS NULL;

-- ── audit_log (replace, do not add: every business write maintains these) ────
CREATE INDEX CONCURRENTLY IF NOT EXISTS audit_log_at_id_idx
  ON public.audit_log (at DESC, id DESC);
CREATE INDEX CONCURRENTLY IF NOT EXISTS audit_log_table_at_idx
  ON public.audit_log (table_name, at DESC, id DESC);
CREATE INDEX CONCURRENTLY IF NOT EXISTS audit_log_actor_at_idx
  ON public.audit_log (actor_id, at DESC, id DESC);
DROP INDEX CONCURRENTLY IF EXISTS public.audit_log_at_idx;
DROP INDEX CONCURRENTLY IF EXISTS public.audit_log_actor_idx;
-- keep audit_log_row_idx (table_name, row_id) for per-record history

-- ── system_users: case-insensitive uniqueness behind the ilike login lookup ──
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS system_users_username_lower_uidx
  ON public.system_users (lower(username));

-- ── Tables whose migrations are not in this repo: guarded, non-concurrent (small tables) ──
DO $$ BEGIN
  IF to_regclass('public.sites') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS sites_organisation_idx ON public.sites (organisation_id);
  END IF;
  IF to_regclass('public.deal_contacts') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS deal_contacts_deal_idx   ON public.deal_contacts (deal_id);
    CREATE INDEX IF NOT EXISTS deal_contacts_person_idx ON public.deal_contacts (person_id);
  END IF;
  IF to_regclass('public.engagement_milestones') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS engagement_milestones_engagement_idx ON public.engagement_milestones (engagement_id);
    CREATE INDEX IF NOT EXISTS engagement_milestones_status_idx     ON public.engagement_milestones (status, proposed_at);
  END IF;
  IF to_regclass('public.engagement_people') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS engagement_people_engagement_idx ON public.engagement_people (engagement_id);
  END IF;
  IF to_regclass('public.lead_stage_requests') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS lead_stage_requests_lead_idx    ON public.lead_stage_requests (lead_id, requested_at DESC);
    CREATE INDEX IF NOT EXISTS lead_stage_requests_pending_idx ON public.lead_stage_requests (request_type) WHERE status = 'pending';
  END IF;
  IF to_regclass('public.sales_campaign_organisations') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS sales_campaign_organisations_org_idx ON public.sales_campaign_organisations (organisation_id);
  END IF;
  IF to_regclass('public.user_presence') IS NOT NULL THEN
    -- needed by heartbeat()'s ON CONFLICT (04_heartbeat_and_sweeps.sql)
    CREATE UNIQUE INDEX IF NOT EXISTS user_presence_person_uidx ON public.user_presence (person_id);
  END IF;
END $$;

-- ── refresh planner statistics ───────────────────────────────────────────────
ANALYZE public.engagements;
ANALYZE public.leads;
ANALYZE public.deals;
ANALYZE public.organisations;
ANALYZE public.person_organisation_roles;
ANALYZE public.audit_log;

-- After a week in prod, anything with idx_scan = 0 on a business table is a candidate to drop:
--   select relname, indexrelname, idx_scan from pg_stat_user_indexes
--    where schemaname = 'public' order by idx_scan, relname;
