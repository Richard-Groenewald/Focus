-- Lead stage renames (v7.8.15):
--   'Nurture' (parked / wake-date stage) → back to 'Dormant'. The stage is
--     RETIRED: no route in remains (the promote wizard's park branch is gone);
--     legacy rows keep wake_date and derive to Dormant; the leads tab shows
--     only while such rows exist. Org client_status 'Dormant' is unrelated.
--   'Priority' (manual focus stage between Working and Qualified) → 'Nurture'.
--
-- Run on BOTH Dev and Prod BEFORE releasing v7.8.15 code.
-- Order matters twice over: the parked rows must vacate the 'Nurture' name
-- before the Priority rows take it, and the new CHECK validates existing rows.

ALTER TABLE leads DROP CONSTRAINT IF EXISTS leads_status_check;

-- Pure renames — skip audit/refresh triggers (no semantic change per lead).
SET session_replication_role = replica;
UPDATE leads SET status = 'Dormant' WHERE status = 'Nurture';
UPDATE leads SET status = 'Nurture' WHERE status = 'Priority';
SET session_replication_role = DEFAULT;

ALTER TABLE leads ADD CONSTRAINT leads_status_check
  CHECK (status = ANY (ARRAY[
    'New'::text,
    'Working'::text,
    'Nurture'::text,
    'Qualified'::text,
    'Promoted'::text,
    'Dormant'::text,
    'Dead'::text
  ]));

NOTIFY pgrst, 'reload schema';
