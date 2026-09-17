-- Focus v7.9.51 — Support item categories (2026-09-13). Idempotent. Dev first, then prod.
--
-- The accessory catalogue (quote_accessories) is split into three admin pages:
--   workforce  Workforce Support Items — things an officer carries or needs (pocket book,
--              baton, BPV…); ticked on each post
--   contract   Contract Support Items  — physical things a contract needs to be delivered
--              (site gun safe, bullet trap, base station, vehicle); ticked once per quote
--   service    Service Support Items   — service things a contract needs to be delivered
--              (armed response, monitoring, airtime…); ticked once per quote
-- All three keep the same table, cost history (quote_accessory_costs) and cost
-- model; only the category differs. The client treats a NULL category as workforce
-- so it keeps working before this script has run.

BEGIN;

ALTER TABLE quote_accessories
  ADD COLUMN IF NOT EXISTS category TEXT NOT NULL DEFAULT 'workforce';

ALTER TABLE quote_accessories DROP CONSTRAINT IF EXISTS quote_accessories_category_check;
ALTER TABLE quote_accessories
  ADD CONSTRAINT quote_accessories_category_check
  CHECK (category IN ('workforce','contract','service'));

-- Items whose current cost is already costed "per contract" move to the contract page.
UPDATE quote_accessories a SET category = 'contract'
WHERE a.category = 'workforce'
  AND EXISTS (
    SELECT 1 FROM quote_accessory_costs c
    WHERE c.accessory_id = a.id
      AND c.cost_basis = 'per_contract'
      AND c.effective_date = (SELECT max(effective_date) FROM quote_accessory_costs x
                              WHERE x.accessory_id = a.id AND x.effective_date <= current_date)
  );

CREATE INDEX IF NOT EXISTS quote_accessories_category_idx ON quote_accessories (category);

COMMIT;

-- Verification:
-- SELECT category, count(*) FROM quote_accessories GROUP BY 1;
