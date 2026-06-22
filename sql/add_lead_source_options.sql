-- Lead Sources: configurable lookup + new options
-- =================================================
-- 1. Add an `is_system` flag so the four name-coupled sources (Referral,
--    Client Expansion, Research Campaign, Sales Campaign) can be protected in
--    the new Admin → Lookups → Lead Sources page: editable/deactivatable but
--    name-locked and undeletable, because conditional UI on the lead form keys
--    off their exact name. All other sources are fully user-managed.
-- 2. Add three new sources: Networking Events, Cold Calling, Network Leverage.
--
-- Idempotent: safe to re-run. Assumes rename_research_drop_campaign_sources.sql
-- has already run (so "Research" is now "Research Campaign"); the UPDATE below
-- covers both names just in case.

-- 1. Column ----------------------------------------------------------------
ALTER TABLE public.lead_sources
  ADD COLUMN IF NOT EXISTS is_system boolean NOT NULL DEFAULT false;

-- 2. Flag the system sources (name is load-bearing for lead-form logic) ------
UPDATE public.lead_sources
   SET is_system = true
 WHERE name IN ('Referral', 'Client Expansion', 'Research Campaign', 'Research', 'Sales Campaign');

-- 3. Seed the new sources ---------------------------------------------------
INSERT INTO public.lead_sources (name, active, is_system)
SELECT v.name, true, false
  FROM (VALUES
    ('Networking Events'),
    ('Cold Calling'),
    ('Network Leverage')
  ) AS v(name)
 WHERE NOT EXISTS (
   SELECT 1 FROM public.lead_sources ls WHERE ls.name = v.name
 );
