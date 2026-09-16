-- Focus v7.9.56 — Support items, fresh baseline from the Xone quote tool (2026-09-16).
-- Run on BOTH databases, Test first. Re-running re-applies the same fresh state.
--
-- "Fresh" means: the workforce / contract / service catalogue becomes exactly the quote
-- tool's list below, at the quote tool's CURRENT price per item. Uniforms (category
-- 'uniform', sql/uniforms.sql) are not touched.
--   • An item in the list that already exists (matched by code) is refreshed in place and
--     keeps its id, so post ticks, contract ticks, adjustments and conditions on it stay valid.
--   • A non-uniform item NOT in the list (trial rows such as pepper_spray_old, a1) is deleted
--     with its ticks, adjustments, condition members and cost rows.
--   • Every existing cost row on the listed items is deleted (trial prices would otherwise win
--     as the latest effective row) and the quote tool's current row is inserted.
--   • The item is in use from the price's effective date; "Active = No" in the quote tool
--     becomes active = false (never offered until an admin re-activates it).
--
-- The quote tool holds startup cost + monthly cost + useful life; here that is acquisition
-- amortised over life_months plus monthly running cost, recovery 'amortised', loss 0%.
-- The quote tool has no quantity basis, so the basis is assigned here — change it in Site
-- Admin → Proposal Builder with a new cost row from a date if a different rule is wanted:
--   per officer        personal kit: pocket book, restraints, batons, pepper spray, vest, harness
--   per duty position  shared post kit: torches, umbrella, tazer, non-lethal guns, 9mm, camera, detector
--   per post           occurrence book
--   per contract       bullet trap, site gun safe (category contract)

BEGIN;

CREATE TEMP TABLE fresh_items (
  code TEXT PRIMARY KEY, name TEXT, category TEXT, ord INT, active BOOLEAN,
  effective DATE, acquisition NUMERIC(12,2), life INT, monthly NUMERIC(12,2), basis TEXT
) ON COMMIT DROP;

INSERT INTO fresh_items VALUES
  ('officer_pocket_book',     'Security Officer Pocket Book',        'workforce',  1, true,  DATE '2026-07-29',    11.30, 12,  0.00, 'per_officer'),
  ('restraints_pouch',        'Restraints & Pouch',                  'workforce',  2, true,  DATE '2026-07-29',   164.50, 18,  0.00, 'per_officer'),
  ('baton',                   'Baton',                               'workforce',  3, true,  DATE '2026-07-29',   159.00, 36,  0.00, 'per_officer'),
  ('torch_rubberized',        'Torch/Spotlight - Rubberized',        'workforce',  4, true,  DATE '2026-07-29',   670.95, 10,  0.00, 'per_duty_position'),
  ('umbrella',                'Umbrella',                            'workforce',  5, true,  DATE '2026-07-29',   329.00, 18,  0.00, 'per_duty_position'),
  ('tazer',                   'Tazer (Electric Paralyzer)',          'workforce',  6, true,  DATE '2026-07-29',   388.33, 10,  0.00, 'per_duty_position'),
  ('pepper_spray',            'Pepper Spray',                        'workforce',  7, true,  DATE '2026-07-29',   141.00, 10,  0.00, 'per_officer'),
  ('bullet_proof_vest',       'Bullet Proof Vest',                   'workforce',  8, true,  DATE '2026-07-29',  4391.00, 24,  0.00, 'per_officer'),
  ('non_lethal_paintball',    'Non-Lethal - Paintball Gun',          'workforce',  9, true,  DATE '2026-07-29',  4729.00, 36,  0.00, 'per_duty_position'),
  ('non_lethal_9mm_pellet',   'Non-Lethal - 9mm Pellet Gun',         'workforce', 10, true,  DATE '2026-07-29',  2895.00, 36,  0.00, 'per_duty_position'),
  ('parabellum_9mm',          '9mm Parabellum',                      'workforce', 11, true,  DATE '2023-12-01', 12000.00, 72, 50.00, 'per_duty_position'),
  ('bodyworn_camera',         'Bodyworn camera',                     'workforce', 12, true,  DATE '2026-07-29',  5446.00, 36,  0.00, 'per_duty_position'),
  ('extendable_baton',        'Extendable Baton',                    'workforce', 13, true,  DATE '2026-07-29',   296.00,  8,  0.00, 'per_officer'),
  ('rubberized_baton',        'Rubberized Baton',                    'workforce', 14, false, DATE '2026-07-29',   115.00, 36,  0.00, 'per_officer'),
  ('bullet_trap',             'Bullet Trap',                         'contract',  15, false, DATE '2026-07-29',  8114.00, 72,  0.00, 'per_contract'),
  ('site_gun_safe',           'Site Gun Safe',                       'contract',  16, true,  DATE '2026-07-29',  1895.00, 60,  0.00, 'per_contract'),
  ('bodyworn_harness',        'Bodyworn Harness',                    'workforce', 17, false, DATE '2024-07-08',   407.00, 36,  0.00, 'per_officer'),
  ('handheld_metal_detector', 'Handheld Metal Detector',             'workforce', 18, false, DATE '2026-07-29',  3267.00, 36,  0.00, 'per_duty_position'),
  ('torch_zartek',            'Torch/Spotlight - Zartek hand held',  'workforce', 19, false, DATE '2024-07-08',   945.00, 12,  0.00, 'per_duty_position'),
  ('occurrence_book',         'Occurrence Book',                     'workforce', 20, false, DATE '2026-07-29',    86.00, 12,  0.00, 'per_post');

-- 1. Non-uniform items that are not in the list go, with everything hanging off them.
CREATE TEMP TABLE gone AS
  SELECT id FROM quote_accessories WHERE category <> 'uniform' AND code NOT IN (SELECT code FROM fresh_items);
DELETE FROM quote_post_accessories          WHERE accessory_id IN (SELECT id FROM gone);
DELETE FROM quote_contract_accessories      WHERE accessory_id IN (SELECT id FROM gone);
DELETE FROM quote_workforce_adjustments     WHERE accessory_id IN (SELECT id FROM gone);
DELETE FROM quote_support_item_rule_members WHERE kind = 'support' AND code IN (SELECT id::text FROM gone);
DELETE FROM quote_accessories               WHERE id IN (SELECT id FROM gone);   -- cost rows cascade
DROP TABLE gone;

-- 2. Listed items: refreshed in place by code (ids kept), created where missing.
INSERT INTO quote_accessories (code, name, category, display_order, active, in_use_date, retired_date, description)
SELECT code, name, category, ord, active, effective, NULL, 'Xone quote tool' FROM fresh_items
ON CONFLICT (code) DO UPDATE
   SET name          = EXCLUDED.name,
       category      = EXCLUDED.category,
       display_order = EXCLUDED.display_order,
       active        = EXCLUDED.active,
       in_use_date   = EXCLUDED.in_use_date,
       retired_date  = NULL,
       description   = COALESCE(quote_accessories.description, EXCLUDED.description),
       updated_at    = now();

-- 3. Fresh prices: old cost rows on the listed items go; the quote tool's current row comes in.
DELETE FROM quote_accessory_costs
 WHERE accessory_id IN (SELECT a.id FROM quote_accessories a JOIN fresh_items f ON f.code = a.code);
INSERT INTO quote_accessory_costs (accessory_id, effective_date, acquisition_cost, life_months, monthly_cost, loss_pct_per_year, cost_basis, recovery, note)
SELECT a.id, f.effective, f.acquisition, f.life, f.monthly, 0, f.basis, 'amortised', 'Xone quote tool, current price'
  FROM fresh_items f JOIN quote_accessories a ON a.code = f.code;

COMMIT;

-- Verification:
-- SELECT a.display_order, a.code, a.name, a.category, a.active, a.in_use_date, c.effective_date,
--        c.acquisition_cost, c.life_months, c.monthly_cost, c.cost_basis,
--        round(c.acquisition_cost / c.life_months + c.monthly_cost, 2) AS unit_per_month
-- FROM quote_accessories a LEFT JOIN quote_accessory_costs c ON c.accessory_id = a.id
-- WHERE a.category <> 'uniform' ORDER BY a.display_order;
-- Expected: 20 rows, one cost row each; nothing else non-uniform remains.
