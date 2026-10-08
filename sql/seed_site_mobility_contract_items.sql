-- Site Mobility items as Contract Support Items, Richard 2026-10-08: "Yes, load them as contract
-- support items" (from the old quote tool's Admin > Support Items > Site Mobility page).
-- DATA ONLY, additive, re-runnable: every insert is keyed on code / (accessory_id, effective_date)
-- and does nothing when the row is already there. Run on DEV first. Needs
-- support_item_categories.sql, add_support_subcategories.sql and proposal_generator_accessory_cost_model.sql
-- (all already applied on DEV).
--
-- The old tool's columns map as: Startup Cost -> acquisition_cost, Monthly Cost -> monthly_cost,
-- Useful Life (Months) -> life_months. Focus prices a unit per month as
-- acquisition / life + monthly + acquisition x loss% / 12:
--   Golf Cart       2026-06-17  0 / 36 + 4950.00                     = R4,950.00
--   Bicycle         2023-10-01  0 / 12 + 0                           = R0.00        (older row, kept as history)
--   Bicycle         2025-07-17  5000 / 24 + 50.00                    = R258.33
--   Quad bike 4 x 2 2025-07-17  69560 / 36 + 1000.00                 = R2,932.22
--
-- ASSUMPTIONS (the old page shows neither): basis per_contract (ticked once on the Contract Support
-- Items tab with a quantity), recovery amortised, no loss allowance. created_by is left NULL.
-- All four old rows are Active = Yes, so no item is retired.

BEGIN;

-- 1. The subcategory, under the contract family.
INSERT INTO quote_support_subcategories (category, code, group_name, name, display_order)
SELECT 'contract', 'ct_site_mobility', 'Site Mobility', 'Site Mobility',
       COALESCE((SELECT max(display_order) FROM quote_support_subcategories WHERE category = 'contract'), 0) + 1
ON CONFLICT (code) WHERE code IS NOT NULL DO NOTHING;

-- 2. The items, each in use from its first cost row.
INSERT INTO quote_accessories (code, name, category, subcategory_id, in_use_date, display_order, active)
SELECT v.code, v.name, 'contract', s.id, v.in_use::date, v.ord, true
  FROM (VALUES
    ('golf_cart',       'Golf Cart',       '2026-06-17', 1),
    ('bicycle',         'Bicycle',         '2023-10-01', 2),
    ('quad_bike_4_x_2', 'Quad bike 4 x 2', '2025-07-17', 3)
  ) AS v(code, name, in_use, ord)
  JOIN quote_support_subcategories s ON s.code = 'ct_site_mobility'
ON CONFLICT (code) DO NOTHING;

-- 3. The dated cost rows (one per price change, never edited).
INSERT INTO quote_accessory_costs (accessory_id, effective_date, acquisition_cost, life_months, monthly_cost,
                                   loss_pct_per_year, cost_basis, recovery, note)
SELECT a.id, v.eff::date, v.acq, v.life, v.mon, 0, 'per_contract', 'amortised', 'Loaded from the old quote tool'
  FROM (VALUES
    ('golf_cart',       '2026-06-17',     0.00, 36, 4950.00),
    ('bicycle',         '2023-10-01',     0.00, 12,    0.00),
    ('bicycle',         '2025-07-17',  5000.00, 24,   50.00),
    ('quad_bike_4_x_2', '2025-07-17', 69560.00, 36, 1000.00)
  ) AS v(code, eff, acq, life, mon)
  JOIN quote_accessories a ON a.code = v.code AND a.category = 'contract'
ON CONFLICT (accessory_id, effective_date) DO NOTHING;

COMMIT;

-- Verify: 3 items, 4 cost rows, current monthly figures as above.
SELECT a.name, a.in_use_date, c.effective_date, c.acquisition_cost, c.life_months, c.monthly_cost,
       round(c.acquisition_cost / NULLIF(c.life_months, 0) + c.monthly_cost, 2) AS monthly_per_unit
  FROM quote_accessories a
  JOIN quote_accessory_costs c ON c.accessory_id = a.id
 WHERE a.code IN ('golf_cart', 'bicycle', 'quad_bike_4_x_2')
 ORDER BY a.display_order, c.effective_date;
