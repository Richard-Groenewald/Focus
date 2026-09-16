-- Focus v7.9.56 — Contract and Service support items, fresh baseline from the Xone quote tool
-- (2026-09-16). Run on BOTH databases, Test first. Re-running re-applies the same fresh state.
--
-- The quote tool's contract-level list (office kit, radios, monitoring, cellphones, dogs,
-- cleaning, guard hut, fire extinguishers, Instacom subscriptions, Halo radio). In Focus these
-- are ticked once per quote with a quantity on the Contract Support Items tab, so every item
-- is basis per_contract; physical things are category 'contract', monthly services 'service'.
--   • Listed items are upserted by code (ids kept); every old cost row on them is replaced by
--     the quote tool's current row; the item is in use from that row's effective date.
--   • A contract/service item NOT in this list and not in sql/support_items_seed.sql (bullet
--     trap, site gun safe) is removed with its ticks, adjustments, condition members and costs.
--   • Workforce items and uniforms are not touched.
-- Cost mapping (startup + monthly + useful life → acquisition, monthly_cost, life_months):
--   life > 0            → acquisition amortised over life, plus monthly running cost
--   life 0, startup > 0 → once-off to the client (Medical Kit), plus monthly running cost
--   startup 0           → monthly only (life not stored)
-- Worth checking: Polygraphs is captured as startup 800.00 with a useful life of 1 month, which
-- amortises to R800.00 per month per contract — likely meant as a once-off per officer.

BEGIN;

CREATE TEMP TABLE fresh_items (
  code TEXT PRIMARY KEY, name TEXT, category TEXT, ord INT, active BOOLEAN,
  effective DATE, acquisition NUMERIC(12,2), life INT, monthly NUMERIC(12,2)
) ON COMMIT DROP;

INSERT INTO fresh_items VALUES
  ('laptop_computer_and_office',                    'Laptop Computer and Office',                              'contract', 21, true,  DATE '2023-10-01', 13399.00, 36,  210.00),
  ('print_cartridges_and_paper',                    'Print cartridges and paper',                              'contract', 22, true,  DATE '2023-10-01',   650.00,  3,    0.00),
  ('basic_stationary_ob_books_etc',                 'Basic Stationary (OB Books etc.)',                        'contract', 23, true,  DATE '2023-10-01',   250.00,  6,   41.67),
  ('basic_office_equipment',                        'Basic Office Equipment',                                  'contract', 24, true,  DATE '2023-10-01',  3800.00, 48,   79.17),
  ('vehicle_based_radio_simplex',                   'Vehicle Based Radio (Simplex)',                           'contract', 25, true,  DATE '2023-10-01',  3800.00, 60,    0.00),
  ('vehicle_based_radio_repeater',                  'Vehicle Based Radio (Repeater)',                          'contract', 26, true,  DATE '2023-10-01',  4300.00, 60,  130.47),
  ('handheld_radio_local_simplex',                  'Handheld Radio Local (Simplex)',                          'contract', 27, true,  DATE '2023-10-01',  2800.00, 36,    0.00),
  ('handheld_radio_regional_repeater',              'Handheld Radio Regional (Repeater)',                      'contract', 28, true,  DATE '2023-10-01',  2800.00, 24,  115.00),
  ('base_station_radio_repeater',                   'Base Station Radio (Repeater)',                           'contract', 29, true,  DATE '2023-10-01',  4200.00, 36,  130.47),
  ('utrackit_patrol_monitoring_per_patrol',         'Utrackit Patrol Monitoring (per patrol)',                 'service',  30, true,  DATE '2023-10-01',     0.00, 72,  335.00),
  ('site_manager_cellphone',                        'Site Manager cellphone',                                  'service',  31, true,  DATE '2023-10-01',     0.00,  1,  589.00),
  ('site_supervisor_cellphone',                     'Site Supervisor cellphone',                               'service',  32, true,  DATE '2023-10-01',     0.00,  1,  479.00),
  ('cell_phone_r100_airtime',                       'Cell Phone & R100 airtime',                               'contract', 33, true,  DATE '2023-10-01',   350.00,  6,  100.00),
  ('online_intelligence_licence_incident_management','Online Intelligence Licence (Incident management)',      'service',  34, true,  DATE '2023-10-01',     0.00,  1,  260.62),
  ('basic_monthly_cleaning_materials',              'Basic Monthly Cleaning Materials',                        'contract', 35, true,  DATE '2023-10-01',  6200.00, 72,    0.00),
  ('guard_hut',                                     'Guard Hut',                                               'contract', 36, true,  DATE '2023-10-01', 12500.00, 72,    0.00),
  ('polygraphs',                                    'Polygraphs',                                              'service',  37, true,  DATE '2026-07-29',   800.00,  1,    0.00),
  ('vehicle_licence_scanners',                      'Vehicle Licence Scanners',                                'service',  38, true,  DATE '2023-10-01',     0.00,  1, 2500.00),
  ('fire_extinguishers_1_kg_vehicle',               'Fire extinguishers 1 kg (vehicle)',                       'contract', 39, true,  DATE '2026-07-29',   450.00, 60,   13.00),
  ('fire_extinguishers_4_5_kg',                     'Fire extinguishers 4.5 kg',                               'contract', 40, true,  DATE '2026-07-29',   810.00, 60,   13.00),
  ('handheld_thermal',                              'Handheld Thermal',                                        'contract', 41, true,  DATE '2026-07-29', 16500.00, 60,    0.00),
  ('dog_s_brought_to_site',                         'Dog(s) (Brought to site)',                                'service',  42, true,  DATE '2023-10-01',     0.00,  1, 3695.79),
  ('dog_s_stays_on_site',                           'Dog(s) (Stays on site)',                                  'service',  43, true,  DATE '2023-10-01',     0.00,  1, 2695.79),
  ('laser_printer_scanner_duty_cycle_1000_pages_per_month', 'Laser Printer/Scanner (Duty Cycle 1000 pages per month)', 'contract', 44, true, DATE '2024-01-03', 5000.00, 36, 160.00),
  ('incident_management_chase',                     'Incident Management (Chase)',                             'service',  45, false, DATE '2024-01-31',     0.00,  1,  260.62),
  ('remote_camera',                                 'Remote Camera',                                           'contract', 46, false, DATE '2024-01-31',  1200.00, 36,  252.50),
  ('breathalyzer',                                  'Breathalyzer',                                            'contract', 47, false, DATE '2026-07-29',  6245.00, 24,    0.00),
  ('medical_kit',                                   'Medical Kit',                                             'contract', 48, true,  DATE '2026-07-29',   505.28,  0,   50.50),
  ('instacom_rg360_device_and_cradle',              'Instacom - RG360 Device and Cradle',                      'service',  49, true,  DATE '2026-08-31',     0.00,  0,  210.00),
  ('instacom_guard_patrol_pro',                     'Instacom - Guard Patrol Pro',                             'service',  50, true,  DATE '2026-08-31',     0.00,  0,  299.00),
  ('instacom_pc_control',                           'Instacom - PC Control',                                   'service',  51, false, DATE '2026-08-31',     0.00,  0,   29.00),
  ('instacom_mdm_premium_and_support',              'Instacom - MDM Premium and Support',                      'service',  52, true,  DATE '2026-08-31',     0.00,  0,   84.00),
  ('instacom_online_mem_monthly_sub',               'Instacom - Online MEM Monthly Sub.',                      'service',  53, true,  DATE '2026-08-31',     0.00,  0,   39.00),
  ('instacom_mcd_2000_1_channel',                   'Instacom - MCD 2000 - 1 Channel',                         'service',  54, false, DATE '2026-08-31',     0.00,  0,  299.00),
  ('instacom_mcc_push_to_talk',                     'Instacom - MCC - Push to Talk',                           'service',  55, true,  DATE '2026-08-31',     0.00,  0,  119.00),
  ('instacom_mcc_locate',                           'Instacom - MCC - Locate',                                 'service',  56, true,  DATE '2026-08-31',     0.00,  0,   55.00),
  ('instacom_guard_patrol_lite',                    'Instacom - Guard Patrol Lite',                            'service',  57, true,  DATE '2026-08-31',     0.00,  0,  119.00),
  ('instacom_access',                               'Instacom - Access',                                       'service',  58, true,  DATE '2026-08-31',     0.00,  0,  499.00),
  ('instacom_clocking',                             'Instacom - Clocking',                                     'service',  59, true,  DATE '2026-08-31',     0.00,  0,   75.00),
  ('halo_radio',                                    'Halo Radio',                                              'service',  60, true,  DATE '2026-09-01',     0.00,  0,  300.00);

-- 1. Contract / service items that are in neither list go, with everything hanging off them.
CREATE TEMP TABLE gone AS
  SELECT id FROM quote_accessories
   WHERE category IN ('contract', 'service')
     AND code NOT IN (SELECT code FROM fresh_items)
     AND code NOT IN ('bullet_trap', 'site_gun_safe');
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
SELECT a.id, f.effective, f.acquisition,
       CASE WHEN f.acquisition > 0 AND f.life > 0 THEN f.life END,
       f.monthly, 0, 'per_contract',
       CASE WHEN f.acquisition > 0 AND f.life = 0 THEN 'once_off' ELSE 'amortised' END,
       'Xone quote tool, current price'
  FROM fresh_items f JOIN quote_accessories a ON a.code = f.code;

COMMIT;

-- Verification:
-- SELECT a.display_order, a.name, a.category, a.active, a.in_use_date, c.acquisition_cost, c.life_months,
--        c.monthly_cost, c.recovery, round(coalesce(c.acquisition_cost / nullif(c.life_months, 0), 0) + c.monthly_cost, 2) AS unit_per_month
-- FROM quote_accessories a JOIN quote_accessory_costs c ON c.accessory_id = a.id
-- WHERE a.category IN ('contract','service') ORDER BY a.display_order;
-- Expected: 42 rows (these 40 plus bullet trap and site gun safe), one cost row each.
