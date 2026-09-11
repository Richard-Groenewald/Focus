-- Focus v7.9.44 — Accessory cost model (2026-09-11). Idempotent. Dev first, then prod.
--
-- A dated accessory cost row now says what ONE UNIT costs per month and how
-- the client pays for it; how many units a post needs comes from the basis:
--   acquisition_cost / life_months          replacement provision per month
--   + monthly_cost                          running cost (airtime, batteries, licences)
--   + acquisition_cost * loss_pct_per_year / 100 / 12
--   = monthly cost per unit                 (pbAccMonthlyUnit in index.html)
-- Basis → quantity the engine uses:
--   per_officer         officers required for the post (rounded; replacement pool EXCLUDED for now — Richard 2026-09-11)
--   per_duty_position   peak concurrent officers on the post (a torch is shared across shifts)
--   per_post            one
--   per_contract        one per quote — ticked on the Contract Support Items tab, not on a post
-- Recovery → how the client pays:
--   amortised           monthly unit cost × quantity joins the post's monthly price
--   once_off            acquisition × quantity goes on ONE "Setup and equipment" line; running cost still amortised
--   absorbed            costed for margin, never itemised
-- Training is deliberately untouched: it is modelled separately later.

BEGIN;

ALTER TABLE quote_accessory_costs
  ADD COLUMN IF NOT EXISTS acquisition_cost  NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (acquisition_cost >= 0),
  ADD COLUMN IF NOT EXISTS life_months       SMALLINT      CHECK (life_months IS NULL OR life_months > 0),
  ADD COLUMN IF NOT EXISTS monthly_cost      NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (monthly_cost >= 0),
  ADD COLUMN IF NOT EXISTS loss_pct_per_year NUMERIC(5,2)  NOT NULL DEFAULT 0 CHECK (loss_pct_per_year >= 0),
  ADD COLUMN IF NOT EXISTS recovery          TEXT          NOT NULL DEFAULT 'amortised';

-- Carry any v7.9.43 rows across, then retire the old columns and check.
UPDATE quote_accessory_costs
   SET acquisition_cost = CASE WHEN cost_basis LIKE 'once_off%' THEN COALESCE(unit_cost, 0) ELSE acquisition_cost END,
       monthly_cost     = CASE WHEN cost_basis LIKE 'monthly%'  THEN COALESCE(unit_cost, 0) ELSE monthly_cost END
 WHERE unit_cost IS NOT NULL AND cost_basis IN ('once_off_per_officer','once_off_per_post','monthly_per_officer','monthly_per_post');
ALTER TABLE quote_accessory_costs DROP CONSTRAINT IF EXISTS quote_accessory_costs_cost_basis_check;
UPDATE quote_accessory_costs SET cost_basis = CASE
  WHEN cost_basis IN ('once_off_per_officer','monthly_per_officer') THEN 'per_officer'
  WHEN cost_basis IN ('once_off_per_post','monthly_per_post')       THEN 'per_post'
  ELSE cost_basis END;
ALTER TABLE quote_accessory_costs DROP COLUMN IF EXISTS unit_cost;
ALTER TABLE quote_accessory_costs ALTER COLUMN cost_basis SET DEFAULT 'per_officer';
ALTER TABLE quote_accessory_costs
  ADD CONSTRAINT quote_accessory_costs_cost_basis_check
  CHECK (cost_basis IN ('per_officer','per_duty_position','per_post','per_contract'));
ALTER TABLE quote_accessory_costs DROP CONSTRAINT IF EXISTS quote_accessory_costs_recovery_check;
ALTER TABLE quote_accessory_costs
  ADD CONSTRAINT quote_accessory_costs_recovery_check
  CHECK (recovery IN ('amortised','once_off','absorbed'));

-- Per-contract items are ticked on the quote, not on a post.
CREATE TABLE IF NOT EXISTS quote_contract_accessories (
  quote_id     BIGINT      NOT NULL REFERENCES quote_quotes(id) ON DELETE CASCADE,
  accessory_id BIGINT      NOT NULL REFERENCES quote_accessories(id),
  quantity     SMALLINT    NOT NULL DEFAULT 1 CHECK (quantity > 0),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (quote_id, accessory_id)
);

COMMIT;

-- Verification:
-- SELECT column_name FROM information_schema.columns WHERE table_name = 'quote_accessory_costs' ORDER BY ordinal_position;
-- Expected to include acquisition_cost, life_months, monthly_cost, loss_pct_per_year, recovery and NOT unit_cost.
