-- Lead Lifecycle rework — Increment 1 (engine groundwork).
-- Per LEAD_LIFECYCLE_RULES.md (approved 2026-07-26). Run on BOTH DBs (dev first).
-- Verified before writing: zero wake_date rows and zero red-flag-only Dead leads
-- on either DB, so no data remapping is needed anywhere in this migration.

-- 1) Status vocabulary: Dormant (retired, empty) is replaced by Hold (new stage,
--    starts empty — entry flows arrive in increment 2).
ALTER TABLE leads DROP CONSTRAINT leads_status_check;
ALTER TABLE leads ADD CONSTRAINT leads_status_check
  CHECK (status = ANY (ARRAY['New'::text, 'Working'::text, 'Nurture'::text,
                             'Qualified'::text, 'Promoted'::text, 'Hold'::text, 'Dead'::text]));

-- 2) First-engagement stamp. New→Working now requires a first logged engagement;
--    denormalised onto the lead so list sweeps don't count engagements per row
--    (PostgREST cap). Stamped once, never cleared.
ALTER TABLE leads ADD COLUMN first_engaged_at TIMESTAMPTZ;

UPDATE leads l
SET first_engaged_at = e.first_at
FROM (SELECT lead_id, MIN(created_at) AS first_at
      FROM engagements WHERE lead_id IS NOT NULL GROUP BY lead_id) e
WHERE e.lead_id = l.id;

CREATE OR REPLACE FUNCTION trg_leads_stamp_first_engaged() RETURNS trigger AS $$
BEGIN
  IF NEW.lead_id IS NOT NULL THEN
    UPDATE leads SET first_engaged_at = COALESCE(first_engaged_at, NEW.created_at, now())
    WHERE id = NEW.lead_id AND first_engaged_at IS NULL;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER engagements_stamp_first_engaged
  AFTER INSERT ON engagements
  FOR EACH ROW EXECUTE FUNCTION trg_leads_stamp_first_engaged();

-- 3) Retire the special-promotion tunables: Strong-only gates + the automatic
--    flip to Qualified supersede the below-threshold request path.
DELETE FROM settings WHERE key IN ('promotion_min_green', 'promotion_green_counts_weak');
