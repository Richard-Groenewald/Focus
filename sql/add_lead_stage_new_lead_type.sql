-- Adds the placeholder lead stage 'New Lead Type' between Qualified and
-- Promoted (v7.7.99). The stage is manual: a Qualified lead is moved in/out via
-- the lead-form button; the app status engine keeps it sticky.
--
-- The name is a placeholder to be renamed later. Renaming = re-run the
-- constraint swap below with the new name, UPDATE existing rows, and change the
-- LEAD_STAGE_X constant in index.html.
--
-- Run on BOTH Dev and Prod BEFORE releasing v7.7.99 code.

ALTER TABLE leads DROP CONSTRAINT IF EXISTS leads_status_check;
ALTER TABLE leads ADD CONSTRAINT leads_status_check
  CHECK (status = ANY (ARRAY[
    'New'::text,
    'Working'::text,
    'Qualified'::text,
    'New Lead Type'::text,
    'Promoted'::text,
    'Dormant'::text,
    'Dead'::text
  ]));
