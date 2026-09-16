-- Focus v7.9.56 — Uniforms (2026-09-16). Idempotent. Run on BOTH databases, Test first.
--
-- A fourth support item category, 'uniform': what an officer wears. A post picks ONE uniform
-- (radio, plus None) under Uniform, Workforce Support Items and Training; the pick is an
-- ordinary quote_post_accessories row, so it prices per officer through the accessory cost
-- model (acquisition amortised over life_months), rolls up on the Workforce Support Items tab
-- and prints in the proposal's Uniform column. quote_posts.uniform carries the picked name.
--
-- Seeded from the Xone quote tool's Uniform table, LATEST prices (effective 2025-04-23):
--   Basic                2025/04/23  startup 3221.00  monthly 0.00  useful life 10 months
--   Combat               2025/04/23  startup 3500.00  monthly 0.00  useful life 12 months
--   Executive/Corporate  2025/04/23  startup 4200.00  monthly 0.00  useful life 12 months
--   Specialised Uniform  2025/04/23  startup 3380.00  monthly 0.00  useful life 12 months
-- The quote tool's "None" row is not an item here: an unpicked uniform is none.
-- The 2023-03-01 rows (2510 / 2485 / 3180 / 4850) are not loaded — add them as earlier cost
-- rows through Admin → Proposal Builder → Uniforms → Costs if quotes with older start dates
-- must price.

BEGIN;

ALTER TABLE quote_accessories DROP CONSTRAINT IF EXISTS quote_accessories_category_check;
ALTER TABLE quote_accessories
  ADD CONSTRAINT quote_accessories_category_check
  CHECK (category IN ('workforce','contract','service','uniform'));

INSERT INTO quote_accessories (code, name, category, display_order, active, in_use_date, description)
VALUES
  ('uniform_basic',               'Basic uniform',               'uniform', 1, true, '2025-04-23', 'Xone quote tool: Basic'),
  ('uniform_combat',              'Combat uniform',              'uniform', 2, true, '2025-04-23', 'Xone quote tool: Combat'),
  ('uniform_executive_corporate', 'Executive/Corporate uniform', 'uniform', 3, true, '2025-04-23', 'Xone quote tool: Executive/Corporate'),
  ('uniform_specialised',         'Specialised uniform',         'uniform', 4, true, '2025-04-23', 'Xone quote tool: Specialised Uniform')
ON CONFLICT (code) DO NOTHING;

INSERT INTO quote_accessory_costs (accessory_id, effective_date, acquisition_cost, life_months, monthly_cost, loss_pct_per_year, cost_basis, recovery, note)
SELECT a.id, s.effective_date, s.acquisition_cost, s.life_months, 0, 0, 'per_officer', 'amortised', 'Xone quote tool, latest price'
FROM (VALUES
  ('uniform_basic',               DATE '2025-04-23', 3221.00, 10),
  ('uniform_combat',              DATE '2025-04-23', 3500.00, 12),
  ('uniform_executive_corporate', DATE '2025-04-23', 4200.00, 12),
  ('uniform_specialised',         DATE '2025-04-23', 3380.00, 12)
) AS s(code, effective_date, acquisition_cost, life_months)
JOIN quote_accessories a ON a.code = s.code
ON CONFLICT (accessory_id, effective_date) DO NOTHING;

COMMIT;

-- Verification:
-- SELECT a.code, a.name, a.category, c.effective_date, c.acquisition_cost, c.life_months,
--        round(c.acquisition_cost / c.life_months, 2) AS monthly_per_officer
-- FROM quote_accessories a JOIN quote_accessory_costs c ON c.accessory_id = a.id
-- WHERE a.category = 'uniform' ORDER BY a.display_order, c.effective_date;
-- Expected monthly per officer: 322.10 / 291.67 / 350.00 / 281.67
