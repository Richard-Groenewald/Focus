-- Lead stage renames (v7.8.11):
--   'New Lead Type' (placeholder) → 'Priority', now positioned between Working
--     and Qualified (entry is from Working via the lead-form button; exit back
--     to Working lets the status engine re-derive).
--   'Dormant' → 'Nurture' (same semantics: parked with a wake date).
--
-- Run on BOTH Dev and Prod BEFORE releasing v7.8.11 code.
-- Order matters: the new CHECK validates existing rows, so rename rows first.

ALTER TABLE leads DROP CONSTRAINT IF EXISTS leads_status_check;

-- Pure renames — skip audit/refresh triggers (no semantic change per lead).
SET session_replication_role = replica;
UPDATE leads SET status = 'Priority' WHERE status = 'New Lead Type';
UPDATE leads SET status = 'Nurture'  WHERE status = 'Dormant';
SET session_replication_role = DEFAULT;

ALTER TABLE leads ADD CONSTRAINT leads_status_check
  CHECK (status = ANY (ARRAY[
    'New'::text,
    'Working'::text,
    'Priority'::text,
    'Qualified'::text,
    'Promoted'::text,
    'Nurture'::text,
    'Dead'::text
  ]));

NOTIFY pgrst, 'reload schema';
