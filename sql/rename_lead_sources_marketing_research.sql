-- Focus CRM — align lead-source labels with the v7.7.18 menu relabel
-- ----------------------------------------------------------------------------
-- The lead-form source options that attach a lead to a campaign record are
-- renamed to match the new menu labels:
--   "Research Campaign" → "Marketing Campaign"  (links research_campaigns)
--   "Sales Campaign"    → "Research Study"       (links sales_campaigns)
--
-- These are SYSTEM sources whose *name* drives conditional UI; the app (v7.7.18+)
-- matches BOTH the new and old names, so code + DB can update independently.
-- Matched by id AND old name so the update is idempotent and self-guarding.
-- ids are identical on Dev (rfazs) and Prod (kevrf). Run on both.
-- ----------------------------------------------------------------------------

update lead_sources set name = 'Marketing Campaign'
 where id = 3002 and name = 'Research Campaign';

update lead_sources set name = 'Research Study'
 where id = 4000 and name = 'Sales Campaign';

-- Verify --------------------------------------------------------------------
-- select id, name, is_system from lead_sources where id in (3002, 4000);
