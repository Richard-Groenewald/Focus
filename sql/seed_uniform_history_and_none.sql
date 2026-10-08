-- Uniform types: the old quote tool's 2023/03/01 prices and its "None" type, Richard 2026-10-08
-- ("yes go ahead"). DATA ONLY, additive, re-runnable (every insert is guarded; the one UPDATE
-- only moves a date that still holds the value it was loaded with). Run on DEV first.
--
-- DEV already carries the four types at the 2025/04/23 prices. The old tool also lists, per type,
-- an earlier price from 2023/03/01 and a "None" type (all zero, from 2023/07/01):
--   Basic uniform                2023-03-01  2510.00 / 10 months + 1.00 monthly = R252.00
--   Combat uniform               2023-03-01  2485.00 / 12                       = R207.08
--   Executive/Corporate uniform  2023-03-01  3180.00 / 12                       = R265.00
--   Specialised uniform          2023-03-01  4850.00 / 12                       = R404.17
--   None                         2023-07-01  0                                  = R0.00
-- Basis per officer, recovery amortised, no loss allowance (Richard: "per officer, amortised").
-- The old tool shows life 0 for None; Focus takes NULL (a life must be above zero).
--
-- The four types were in use from 2025/04/23 only because that is when the loaded price starts;
-- with an earlier price they are in use from 2023/03/01, so quotes dated before 2025 can price them.

BEGIN;

UPDATE quote_uniform_types
   SET in_use_date = '2023-03-01'
 WHERE code IN ('uniform_basic', 'uniform_combat', 'uniform_executive_corporate', 'uniform_specialised')
   AND in_use_date = '2025-04-23';

INSERT INTO quote_uniform_types (code, name, display_order, active, in_use_date)
SELECT 'uniform_none', 'None', 9, true, '2023-07-01'
 WHERE NOT EXISTS (SELECT 1 FROM quote_uniform_types WHERE code = 'uniform_none');

INSERT INTO quote_uniform_type_costs (uniform_type_id, effective_date, acquisition_cost, life_months, monthly_cost,
                                      loss_pct_per_year, cost_basis, recovery, note)
SELECT t.id, v.eff::date, v.acq, v.life, v.mon, 0, 'per_officer', 'amortised', 'Xone quote tool, earlier price'
  FROM (VALUES
    ('uniform_basic',               '2023-03-01', 2510.00,   10, 1.00),
    ('uniform_combat',              '2023-03-01', 2485.00,   12, 0.00),
    ('uniform_executive_corporate', '2023-03-01', 3180.00,   12, 0.00),
    ('uniform_specialised',         '2023-03-01', 4850.00,   12, 0.00),
    ('uniform_none',                '2023-07-01',    0.00, NULL, 0.00)
  ) AS v(code, eff, acq, life, mon)
  JOIN quote_uniform_types t ON t.code = v.code
 WHERE NOT EXISTS (SELECT 1 FROM quote_uniform_type_costs c
                    WHERE c.uniform_type_id = t.id AND c.effective_date = v.eff::date);

COMMIT;

-- Verify: 5 types, 9 cost rows (four types with two prices, None with one).
SELECT t.name, t.in_use_date, c.effective_date, c.acquisition_cost, c.life_months, c.monthly_cost,
       round(c.acquisition_cost / NULLIF(c.life_months, 0) + c.monthly_cost, 2) AS monthly_per_unit
  FROM quote_uniform_types t
  JOIN quote_uniform_type_costs c ON c.uniform_type_id = t.id
 ORDER BY t.display_order, c.effective_date;
