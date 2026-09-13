-- Focus v7.9.50 — Opportunity suspension on a passed start date (2026-09-13).
-- Idempotent. Dev first, then prod.
--
-- An open opportunity whose start date has arrived without being secured is
-- suspended: its stage becomes "Suspended" (category Opportunity-Open, so it
-- stays on the register), its probability drops to 0, and the stage and
-- probability it came from are kept on the deal so the allocated salesperson
-- can restore them once a workable start date is set (index.html:
-- sweepStaleStartDeals / reviewSuspendedDeal). Rules the client enforces:
--   start date >= order date; revenue projected from the start date only.

BEGIN;

INSERT INTO stages (category_id, name, probability, sort_order, active, min_probability, max_probability, probability_hint)
SELECT c.id, 'Suspended', 0, 5, true, 0, 0, 'Start date passed without securing — set a workable start date to restore the prior stage'
FROM stage_categories c
WHERE c.name = 'Opportunity-Open'
  AND NOT EXISTS (SELECT 1 FROM stages s WHERE s.name = 'Suspended');

ALTER TABLE deals
  ADD COLUMN IF NOT EXISTS suspended_from_stage_id BIGINT REFERENCES stages(id),
  ADD COLUMN IF NOT EXISTS suspended_probability   INTEGER,
  ADD COLUMN IF NOT EXISTS suspended_at            TIMESTAMPTZ;

COMMIT;

-- Verification:
-- SELECT id, name, category_id, sort_order, probability FROM stages WHERE name = 'Suspended';
-- SELECT column_name FROM information_schema.columns WHERE table_name = 'deals' AND column_name LIKE 'suspended%';
