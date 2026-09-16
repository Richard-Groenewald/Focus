-- Focus v7.9.56 — Training course prices, fresh baseline (2026-09-16). Idempotent.
-- Run on BOTH databases, Test first.
--
-- Seeded from the Xone quote tool's Training table. The quote tool prices training as a
-- MONTHLY provision per officer (startup 0.00, useful life 1 month, the whole cost in
-- "Monthly Cost"), so each row maps to a quote_training_costs row with cost_per_officer =
-- the monthly figure and validity_months = 1 (the refresher cycle: every month = a monthly
-- provision). The client labels a 1-month cycle "per officer per month".
--
-- The 12 courses already exist in both databases (phase B2 seed, same names and codes) with
-- no prices and in_use_date = the day the catalogue was seeded (2026-06-22). "Fresh" resets
-- the in-use date to the quote tool's effective date so quotes starting before 2026-06-22
-- can tick them, and adds the price rows. No post ticks or conditions reference training
-- on either database (checked 2026-09-16), so nothing downstream moves.
--
--   Induction training - All staff     2024/01/01   50.00 /officer/month
--   Control Room Operators             2024/01/01  313.00
--   Security Officer (Semi-skilled)    2024/01/01   66.00
--   Supervisors/Shift Leaders          2024/01/01   86.00
--   Contract Manager/Site Seniors      2024/01/01  355.00
--   Dog Handler                        2024/01/01  383.00
--   Regulation 21                      2024/01/01   99.00
--   Fire Fighting                      2024/01/01   12.00
--   Specialised Training               2024/01/01  105.00
--   Armed Response Officers            2024/01/01  190.00
--   Snake Handling                     2024/01/01   71.00
--   First Aid 1-3                      2024/01/01   70.00

BEGIN;

-- Any course missing (a database seeded without phase B2) is created; existing rows are kept
-- with their ids so ticks and conditions stay valid.
INSERT INTO quote_training_courses (code, name, display_order, active)
VALUES
  ('induction_all_staff',           'Induction training - All staff',     1, true),
  ('control_room_operators',        'Control Room Operators',             2, true),
  ('security_officer_semi_skilled', 'Security Officer (Semi-skilled)',    3, true),
  ('supervisors_shift_leaders',     'Supervisors/Shift Leaders',          4, true),
  ('contract_manager_site_seniors', 'Contract Manager/Site Seniors',      5, true),
  ('dog_handler',                   'Dog Handler',                        6, true),
  ('regulation_21',                 'Regulation 21',                      7, true),
  ('fire_fighting',                 'Fire Fighting',                      8, true),
  ('specialised_training',          'Specialised Training',               9, true),
  ('armed_response_officers',       'Armed Response Officers',           10, true),
  ('snake_handling',                'Snake Handling',                    11, true),
  ('first_aid_1_3',                 'First Aid 1-3',                     12, true)
ON CONFLICT (code) DO NOTHING;

-- Fresh baseline: in use from the quote tool's effective date, not retired.
UPDATE quote_training_courses
   SET in_use_date = DATE '2024-01-01',
       retired_date = NULL,
       active = true,
       description = COALESCE(description, 'Xone quote tool'),
       updated_at = now()
 WHERE code IN ('induction_all_staff','control_room_operators','security_officer_semi_skilled','supervisors_shift_leaders',
                'contract_manager_site_seniors','dog_handler','regulation_21','fire_fighting','specialised_training',
                'armed_response_officers','snake_handling','first_aid_1_3')
   AND (in_use_date IS DISTINCT FROM DATE '2024-01-01' OR retired_date IS NOT NULL OR active IS DISTINCT FROM true);

INSERT INTO quote_training_costs (training_course_id, effective_date, cost_per_officer, validity_months, note)
SELECT t.id, DATE '2024-01-01', s.monthly, 1, 'Xone quote tool: monthly provision per officer'
FROM (VALUES
  ('induction_all_staff',            50.00),
  ('control_room_operators',        313.00),
  ('security_officer_semi_skilled',  66.00),
  ('supervisors_shift_leaders',      86.00),
  ('contract_manager_site_seniors', 355.00),
  ('dog_handler',                   383.00),
  ('regulation_21',                  99.00),
  ('fire_fighting',                  12.00),
  ('specialised_training',          105.00),
  ('armed_response_officers',       190.00),
  ('snake_handling',                 71.00),
  ('first_aid_1_3',                  70.00)
) AS s(code, monthly)
JOIN quote_training_courses t ON t.code = s.code
ON CONFLICT (training_course_id, effective_date) DO NOTHING;

COMMIT;

-- Verification:
-- SELECT t.display_order, t.name, t.in_use_date, c.effective_date, c.cost_per_officer, c.validity_months
-- FROM quote_training_courses t LEFT JOIN quote_training_costs c ON c.training_course_id = t.id
-- ORDER BY t.display_order, c.effective_date;
-- Expected: 12 rows, every course in use from 2024-01-01 with one cost row (validity 1).
