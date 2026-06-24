-- Focus CRM — blended (multi-category) Service Focus
-- ----------------------------------------------------------------------------
-- Lets a campaign or lead target more than one service major (a turn-key deal
-- spans Manpower + Technology, etc.). Adds service_major_ids (BIGINT[]) to the
-- early-funnel tables and backfills it from the existing single service_major_id.
--
-- service_major_id is KEPT as the "primary" focus (= service_major_ids[0]) so the
-- promote wizard, lifecycle gating and any legacy reads keep working unchanged.
-- Line-level blend (multiple revenue lines) continues to live on the opportunity
-- via streams — these columns are intent only, no financial meaning.
--
-- Idempotent: safe to re-run. Run on Dev first; promote to prod when ready.
-- Run AFTER add_advisory_service_category.sql.
-- ----------------------------------------------------------------------------

-- 1. Add the array columns -----------------------------------------------------
alter table research_campaigns add column if not exists service_major_ids bigint[];
alter table sales_campaigns    add column if not exists service_major_ids bigint[];
alter table leads              add column if not exists service_major_ids bigint[];

-- 2. Backfill from the existing single value -----------------------------------
update research_campaigns
   set service_major_ids = array[service_major_id]
 where service_major_id is not null
   and service_major_ids is null;

update sales_campaigns
   set service_major_ids = array[service_major_id]
 where service_major_id is not null
   and service_major_ids is null;

update leads
   set service_major_ids = array[service_major_id]
 where service_major_id is not null
   and service_major_ids is null;

-- Verify -----------------------------------------------------------------------
-- select id, name, service_major_id, service_major_ids from research_campaigns order by id;
-- select id, name, service_major_id, service_major_ids from sales_campaigns    order by id;
-- select id,       service_major_id, service_major_ids from leads              order by id limit 50;
