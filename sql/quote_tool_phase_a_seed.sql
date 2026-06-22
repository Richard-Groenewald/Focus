-- ═══════════════════════════════════════════════════════════════════════
-- Quote Tool — Phase A seed data (PROPOSAL, NOT EXECUTED)
-- ═══════════════════════════════════════════════════════════════════════
-- Target: Dev (test branch) only. Run AFTER quote_tool_phase_a.sql.
--
-- Source: the verified seed data from the quote-posts prototype
-- (quote-posts-prototype.html, defaultHrAdminData()), which mirrors what
-- Richard confirmed against the Xone admin screens.
--
-- All inserts reference lookup IDs by code via sub-SELECT, so they work
-- regardless of which BIGSERIAL values get assigned.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. LOOKUPS ────────────────────────────────────────────────────────

INSERT INTO quote_grades (code, description, display_order) VALUES
  ('A', 'Grade A', 1),
  ('B', 'Grade B', 2),
  ('C', 'Grade C', 3),
  ('D', 'Grade D', 4),
  ('E', 'Grade E', 5)
ON CONFLICT (code) DO NOTHING;

INSERT INTO quote_areas (code, description, display_order) VALUES
  ('area_1', 'Area 1 (Major Urban)', 1),
  ('area_2', 'Area 2 (Urban)',       2),
  ('area_3', 'Area 3 (Other)',       3)
ON CONFLICT (code) DO NOTHING;

INSERT INTO quote_leave_types (code, description, display_order) VALUES
  ('sick',                  'Sick Leave',             1),
  ('annual',                'Annual Leave',           2),
  ('family_responsibility', 'Family Responsibility',  3),
  ('maternity',             'Maternity Leave',        4),
  ('study',                 'Study Leave',            5)
ON CONFLICT (code) DO NOTHING;

INSERT INTO quote_shared_salary_option_types (code, description, display_order) VALUES
  ('health_insurance',          'Health Insurance',          1),
  ('provident_fund',            'Provident Fund',            2),
  ('bargaining_council_levy',   'Bargaining Council Levy',   3),
  ('compensation_commissioner', 'Compensation Commissioner', 4),
  ('uif',                       'UIF',                       5),
  ('sdl',                       'SDL',                       6)
ON CONFLICT (code) DO NOTHING;

-- ── 2. STATUTORY SALARY RATES ────────────────────────────────────────
-- 16 rows across 2023/2024/2025 effective dates (from the visible Xone data).

INSERT INTO quote_salary_rates (effective_date, grade_id, area_id, monthly_salary, hourly_rate) VALUES
  -- 2023/03/01
  ('2023-03-01', (SELECT id FROM quote_grades WHERE code='A'), (SELECT id FROM quote_areas WHERE code='area_1'), 6907.00, 33.2100),
  ('2023-03-01', (SELECT id FROM quote_grades WHERE code='B'), (SELECT id FROM quote_areas WHERE code='area_1'), 6330.00, 30.4300),
  ('2023-03-01', (SELECT id FROM quote_grades WHERE code='C'), (SELECT id FROM quote_areas WHERE code='area_1'), 5726.00, 27.5300),
  ('2023-03-01', (SELECT id FROM quote_grades WHERE code='A'), (SELECT id FROM quote_areas WHERE code='area_3'), 5915.00, 28.4400),
  ('2023-03-01', (SELECT id FROM quote_grades WHERE code='B'), (SELECT id FROM quote_areas WHERE code='area_3'), 5499.00, 26.4400),
  ('2023-03-01', (SELECT id FROM quote_grades WHERE code='C'), (SELECT id FROM quote_areas WHERE code='area_3'), 5499.00, 26.4400),
  -- 2024/03/01
  ('2024-03-01', (SELECT id FROM quote_grades WHERE code='A'), (SELECT id FROM quote_areas WHERE code='area_1'), 7277.00, 34.9900),
  ('2024-03-01', (SELECT id FROM quote_grades WHERE code='B'), (SELECT id FROM quote_areas WHERE code='area_1'), 6700.00, 32.2100),
  ('2024-03-01', (SELECT id FROM quote_grades WHERE code='C'), (SELECT id FROM quote_areas WHERE code='area_1'), 6096.00, 29.3100),
  ('2024-03-01', (SELECT id FROM quote_grades WHERE code='A'), (SELECT id FROM quote_areas WHERE code='area_3'), 6271.00, 30.1500),
  ('2024-03-01', (SELECT id FROM quote_grades WHERE code='B'), (SELECT id FROM quote_areas WHERE code='area_3'), 5855.00, 28.1500),
  ('2024-03-01', (SELECT id FROM quote_grades WHERE code='C'), (SELECT id FROM quote_areas WHERE code='area_3'), 5855.00, 28.1500),
  -- 2025/03/01
  ('2025-03-01', (SELECT id FROM quote_grades WHERE code='A'), (SELECT id FROM quote_areas WHERE code='area_1'), 7695.00, 37.0000),
  ('2025-03-01', (SELECT id FROM quote_grades WHERE code='B'), (SELECT id FROM quote_areas WHERE code='area_1'), 7118.00, 34.2200),
  ('2025-03-01', (SELECT id FROM quote_grades WHERE code='C'), (SELECT id FROM quote_areas WHERE code='area_1'), 6514.00, 31.3200),
  ('2025-03-01', (SELECT id FROM quote_grades WHERE code='A'), (SELECT id FROM quote_areas WHERE code='area_3'), 6672.00, 32.0800);

-- ── 3. EXTRAORDINARY HOURS RATES ─────────────────────────────────────
-- 1 row. Multipliers are premium-only (see xone-multiplier-convention memory).

INSERT INTO quote_extraordinary_hour_rates (effective_date, overtime_multiplier, sunday_multiplier, public_holiday_multiplier) VALUES
  ('2023-03-01', 1.500, 1.500, 1.000);

-- ── 4. STATUTORY ALLOWANCES ──────────────────────────────────────────
-- 32 rows across 2023/2024/2025/2026 effective dates.
-- code = stable slug for the calc engine; description = display label.

INSERT INTO quote_statutory_allowances (effective_date, code, description, rate, occurrence_type) VALUES
  -- 2023/03/01
  ('2023-03-01', 'control_centre_operator',   'Control Centre Operator',    8.50, 'shift'),
  ('2023-03-01', 'mobile_supervisor',         'Mobile Supervisor',          8.50, 'shift'),
  ('2023-03-01', 'armed_response_officer',    'Armed Response Officer',     8.50, 'shift'),
  ('2023-03-01', 'armed_security_operator',   'Armed Security Operator',    8.50, 'shift'),
  ('2023-03-01', 'national_key_point_officer','National Key Point Officer', 8.50, 'shift'),
  ('2023-03-01', 'cleaning',                  'Cleaning Allowance',         30.00,'monthly'),
  ('2023-03-01', 'night_shift',               'Night Shift',                6.00, 'shift'),
  ('2023-03-01', 'canine_dog_handler',        'Canine/Dog Handler',         8.50, 'shift'),
  -- 2024/03/01 (rate increases)
  ('2024-03-01', 'night_shift',               'Night Shift',                7.00, 'shift'),
  ('2024-03-01', 'armed_security_operator',   'Armed Security Operator',    9.50, 'shift'),
  ('2024-03-01', 'cleaning',                  'Cleaning Allowance',         31.00,'monthly'),
  ('2024-03-01', 'control_centre_operator',   'Control Centre Operator',    9.50, 'shift'),
  ('2024-03-01', 'canine_dog_handler',        'Canine/Dog Handler',         9.50, 'shift'),
  ('2024-03-01', 'mobile_supervisor',         'Mobile Supervisor',          9.50, 'shift'),
  ('2024-03-01', 'armed_response_officer',    'Armed Response Officer',     9.50, 'shift'),
  ('2024-03-01', 'national_key_point_officer','National Key Point Officer', 9.50, 'shift'),
  -- 2025/03/01 (held flat)
  ('2025-03-01', 'national_key_point_officer','National Key Point Officer', 9.50, 'shift'),
  ('2025-03-01', 'canine_dog_handler',        'Canine/Dog Handler',         9.50, 'shift'),
  ('2025-03-01', 'armed_response_officer',    'Armed Response Officer',     9.50, 'shift'),
  ('2025-03-01', 'mobile_supervisor',         'Mobile Supervisor',          9.50, 'shift'),
  ('2025-03-01', 'control_centre_operator',   'Control Centre Operator',    9.50, 'shift'),
  ('2025-03-01', 'cleaning',                  'Cleaning Allowance',         31.00,'monthly'),
  ('2025-03-01', 'armed_security_operator',   'Armed Security Operator',    9.50, 'shift'),
  ('2025-03-01', 'night_shift',               'Night Shift',                7.00, 'shift'),
  -- 2026/03/01 (next increase)
  ('2026-03-01', 'night_shift',               'Night Shift',                8.00, 'shift'),
  ('2026-03-01', 'armed_security_operator',   'Armed Security Operator',    10.50,'shift'),
  ('2026-03-01', 'cleaning',                  'Cleaning Allowance',         32.00,'monthly'),
  ('2026-03-01', 'control_centre_operator',   'Control Centre Operator',    10.50,'shift'),
  ('2026-03-01', 'mobile_supervisor',         'Mobile Supervisor',          10.50,'shift'),
  ('2026-03-01', 'armed_response_officer',    'Armed Response Officer',     10.50,'shift'),
  ('2026-03-01', 'canine_dog_handler',        'Canine/Dog Handler',         10.50,'shift'),
  ('2026-03-01', 'national_key_point_officer','National Key Point Officer', 10.50,'shift');

-- ── 5. LEAVE ALLOCATIONS ─────────────────────────────────────────────
-- 5 leave types, each one row at the baseline date.

INSERT INTO quote_leave_allocations (effective_from_date, leave_type_id, no_of_days, cycle_days, average_utilisation) VALUES
  ('2023-03-01', (SELECT id FROM quote_leave_types WHERE code='sick'),                  30,  1095, 60.00),
  ('2023-03-01', (SELECT id FROM quote_leave_types WHERE code='annual'),                22,  365,  100.00),
  ('2023-03-01', (SELECT id FROM quote_leave_types WHERE code='family_responsibility'),  5,  365,  66.00),
  ('2023-03-01', (SELECT id FROM quote_leave_types WHERE code='maternity'),             120, 365,  1.00),
  ('2023-03-01', (SELECT id FROM quote_leave_types WHERE code='study'),                  6,  365,  5.00);

-- ── 6. SHARED SALARY OPTIONS ─────────────────────────────────────────
-- One row per type. employee/employer values per type vary in meaning:
-- Provident Fund + UIF + SDL → percentages; Health Insurance + Bargaining
-- Council + Compensation Commissioner → absolute amounts. UI/calc engine
-- knows which is which by type code.

INSERT INTO quote_shared_salary_options (effective_date, shared_salary_option_type_id, employee_contribution, employer_contribution, threshold) VALUES
  ('2023-03-01', (SELECT id FROM quote_shared_salary_option_types WHERE code='health_insurance'),           0.0000, 172.5000, 0.00),
  ('2023-03-01', (SELECT id FROM quote_shared_salary_option_types WHERE code='provident_fund'),             7.5000, 7.5000,   0.00),
  ('2023-03-01', (SELECT id FROM quote_shared_salary_option_types WHERE code='bargaining_council_levy'),    0.0000, 7.0000,   0.00),
  ('2023-03-01', (SELECT id FROM quote_shared_salary_option_types WHERE code='compensation_commissioner'),  0.0000, 2.6500,   0.00),
  ('2023-03-01', (SELECT id FROM quote_shared_salary_option_types WHERE code='uif'),                        1.0000, 1.0000,   0.00),
  ('2023-03-01', (SELECT id FROM quote_shared_salary_option_types WHERE code='sdl'),                        0.0000, 1.0000,   0.00);

-- ── 7. CALCULATION RATIOS ────────────────────────────────────────────
-- 12 named ratios. Code = stable slug; description = human label;
-- ratio_value = TEXT to preserve precision of computed ratios.

INSERT INTO quote_calculation_ratios (effective_date, code, description, ratio_value, unit, enabled) VALUES
  ('2024-01-02', 'avg_sunday_hours_per_month',          'Average Sunday hours per person per month',         '34.78571429', 'Hours',  true),
  ('2024-01-02', 'avg_ph_hours_per_month',              'Average Public Holiday hours per person per month', '8.83333333',  'Hours',  true),
  ('2024-01-02', 'max_overtime_hours_per_month',        'Maximum Overtime hours per person per month',       '52.17857',    'Hours',  true),
  ('2024-01-02', 'avg_night_shifts_per_month',          'Average Night Shifts person per month',             '10.14583',    'Shifts', true),
  ('2024-01-02', 'monthly_bonus_provision_pct',         'Monthly Bonus Provision %',                         '8.33333333',  '%',      true),
  ('2024-01-02', 'monthly_5yr_service_bonus_provision', 'Monthly 5-year Service Bonus Provision',            '8.3333333',   'Rand',   true),
  ('2024-01-17', 'psira_contribution',                  'Psira Contribution',                                '4.6',         'Rand',   true),
  ('2024-01-17', 'area_manager_overhead',               'Area Manager Overhead',                             '0',           '%',      true),
  ('2024-01-17', 'replacement_pool_provision',          'Replacement Pool Provision',                        '0',           '%',      true),
  ('2023-12-01', 'avg_shifts_per_month',                'Average Shifts per person per Month',               '20.29166667', 'Shifts', true),
  ('2024-05-26', 'min_fixed_salary_to_psira_ratio',     'Minimum Fixed Salary to PSIRA Ratio',               '1',           'Numeric Multiplier', true),
  ('2024-06-01', 'avg_unauthorised_absent_days',        'Average number of unauthorised absent days per month', '2',        'Days',   true);

-- ── 8. DISCRETIONARY ALLOWANCES (catalog) ────────────────────────────
-- Rich descriptions from the Xone admin screen.

INSERT INTO quote_discretionary_allowances (effective_date, code, name, description, display_order) VALUES
  ('2023-03-01', 'seniority',       'Seniority Allowance',       'Rank and/or duration in the role.', 1),
  ('2023-03-01', 'supervisor',      'Supervisor Allowance',      'Works in a supervisory capacity, oversees team. Small sites with no Contract Manager. Senior staff allocated this allowance to pick up additional managerial work.', 2),
  ('2023-03-01', 'drivers',         'Drivers Allowance',         'Driving vehicles as per role requirement. eg. Armed Response Officers and RSI''s', 3),
  ('2023-03-01', 'transport',       'Transport Allowance',       'Allocated to sites where client pays for transport for staff', 4),
  ('2023-03-01', 'top_up',          'Top Up Allowance',          'Add this to increase total earnings. Eg PAR Staff', 5),
  ('2023-03-01', 'special_post',    'Special Post Allowance',    'Danger, inconvenience, complexity of role and responsibilities', 6),
  ('2023-03-01', 'customer_funded', 'Customer Funded Allowance', 'Paid specifically by clients - e.g. UWC.', 7),
  ('2023-03-01', 'stand_in',        'Stand-In Allowance',        'Ad-hoc allowance paid for leave stand-in', 8),
  ('2023-03-01', 'standby',         'Standby Allowance',         'Paid to Technician - only if they are rostered to be on standby.', 9);

-- ── 9. DISCRETIONARY INCENTIVES (catalog) ────────────────────────────

INSERT INTO quote_discretionary_incentives (effective_date, code, name, description, display_order) VALUES
  ('2023-03-01', 'performance', 'Performance Incentive', 'Performance Incentive', 1),
  ('2023-03-01', 'attendance',  'Attendance Incentive',  'Attendance Incentive',  2);

COMMIT;

-- ═══════════════════════════════════════════════════════════════════════
-- Verification queries (run these after seeding to sanity-check)
-- ═══════════════════════════════════════════════════════════════════════
--
-- SELECT 'salary rates'          AS what, count(*) FROM quote_salary_rates
-- UNION ALL SELECT 'eh rates',             count(*) FROM quote_extraordinary_hour_rates
-- UNION ALL SELECT 'statutory allowances', count(*) FROM quote_statutory_allowances
-- UNION ALL SELECT 'leave allocations',    count(*) FROM quote_leave_allocations
-- UNION ALL SELECT 'shared salary options',count(*) FROM quote_shared_salary_options
-- UNION ALL SELECT 'calc ratios',          count(*) FROM quote_calculation_ratios
-- UNION ALL SELECT 'disc allowances',      count(*) FROM quote_discretionary_allowances
-- UNION ALL SELECT 'disc incentives',      count(*) FROM quote_discretionary_incentives;
--
-- Expected totals:
--   salary rates: 16
--   eh rates:     1
--   statutory:    32
--   leave:        5
--   shared:       6
--   calc ratios:  12
--   disc allow:   9
--   disc incent:  2
-- ═══════════════════════════════════════════════════════════════════════
