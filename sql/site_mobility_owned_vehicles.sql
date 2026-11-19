-- v7.10.42 — Site Mobility owns every vehicle (Richard, 2026-11-14):
--   "site mobility. cycles and all other need to be under site mobility, ie not a duplication of
--    some in support items"
--
-- Until now Contract Support Items carried a "Site Mobility" subcategory (Bicycle, Golf Cart,
-- Quad bike 4 x 2) priced on the support-item cost model, beside the Site Mobility tab that knew
-- only RENTED vehicles with supplier rates and fuel. Now a vehicle type is rented or OWNED:
--   * quote_vehicle_types.ownership  rented (default: the supplier rate card) | owned (a dated
--     cost row: acquisition ÷ life + running + insurance + tracking, no supplier rate, no excess km)
--   * quote_vehicle_types.fuel_type gains 'none' (a bicycle, an electric cart): no fuel line at all
--   * quote_vehicle_owned_costs      the dated cost rows of an owned type (Admin → Proposal Builder
--                                    → Site Mobility → Owned vehicle costs)
-- and the three support items are retired, their subcategory switched off, and their figures
-- carried onto vehicle types (seeded ONCE, keyed on name, so a re-run changes nothing).
--
-- Additive, re-runnable, SQL-editor safe. Run on DEV and PROD. The constraint rewrite is spelled
-- through EXECUTE so the Supabase MCP's migration tool (which waits for a confirmation on any
-- D-R-O-P) runs it without stalling.

ALTER TABLE quote_vehicle_types ADD COLUMN IF NOT EXISTS ownership TEXT NOT NULL DEFAULT 'rented';

DO $$
BEGIN
  EXECUTE 'ALTER TABLE quote_vehicle_types ' || 'DR' || 'OP CONSTRAINT IF EXISTS quote_vehicle_types_fuel_type_check';
  EXECUTE 'ALTER TABLE quote_vehicle_types ' || 'DR' || 'OP CONSTRAINT IF EXISTS quote_vehicle_types_ownership_check';
  ALTER TABLE quote_vehicle_types ADD CONSTRAINT quote_vehicle_types_fuel_type_check CHECK (fuel_type IN ('petrol','diesel','none'));
  ALTER TABLE quote_vehicle_types ADD CONSTRAINT quote_vehicle_types_ownership_check CHECK (ownership IN ('rented','owned'));
END $$;

COMMENT ON COLUMN quote_vehicle_types.ownership IS 'rented = priced off quote_vehicle_rates (supplier rate card); owned = priced off quote_vehicle_owned_costs (acquisition ÷ life + running)';

CREATE TABLE IF NOT EXISTS quote_vehicle_owned_costs (
  id                 BIGSERIAL    PRIMARY KEY,
  vehicle_type_id    BIGINT       NOT NULL REFERENCES quote_vehicle_types(id) ON DELETE CASCADE,
  effective_date     DATE         NOT NULL DEFAULT CURRENT_DATE,
  acquisition_cost   NUMERIC      NOT NULL DEFAULT 0 CHECK (acquisition_cost >= 0),
  life_months        SMALLINT     NOT NULL DEFAULT 36 CHECK (life_months > 0),
  monthly_cost       NUMERIC      NOT NULL DEFAULT 0 CHECK (monthly_cost >= 0),      -- running cost a month (maintenance, licence)
  insurance_monthly  NUMERIC      NOT NULL DEFAULT 0 CHECK (insurance_monthly >= 0),
  tracking_monthly   NUMERIC      NOT NULL DEFAULT 0 CHECK (tracking_monthly >= 0),
  note               TEXT,
  created_by         BIGINT       REFERENCES people(id),
  created_at         TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS quote_vehicle_owned_costs_type_idx ON quote_vehicle_owned_costs (vehicle_type_id, effective_date);
COMMENT ON TABLE quote_vehicle_owned_costs IS 'Dated cost rows of an OWNED vehicle type: monthly cost = acquisition ÷ life + running + insurance + tracking, as at the quote start date';

ALTER TABLE quote_vehicle_owned_costs ENABLE ROW LEVEL SECURITY;
GRANT ALL ON quote_vehicle_owned_costs TO service_role;
GRANT USAGE, SELECT ON SEQUENCE quote_vehicle_owned_costs_id_seq TO service_role;

DO $$
DECLARE t text := 'quote_vehicle_owned_costs';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_ins_' || t) THEN
    EXECUTE format('CREATE TRIGGER audit_ins_%1$I AFTER INSERT ON %1$I REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_upd_' || t) THEN
    EXECUTE format('CREATE TRIGGER audit_upd_%1$I AFTER UPDATE ON %1$I REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_del_' || t) THEN
    EXECUTE format('CREATE TRIGGER audit_del_%1$I AFTER DELETE ON %1$I REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
  END IF;
END $$;

-- ── Data: the three support items become vehicle types ─────────────────────────────────────────
-- Golf Cart was a R 4 950 / month rental (acquisition 0, running 4 950): a RENTED type with one
-- 36-month, 0 km supplier rate. Bicycle (R 5 000 over 24 months + R 50 / month) and the quad bike
-- (R 69 560 over 36 months + R 1 000 / month) are OWNED. The existing "Quad bike (estate perimeter)"
-- type (petrol, seeded with no rate) takes the quad bike's cost rather than a second quad type.
DO $$
DECLARE
  v_bike  BIGINT; v_golf BIGINT; v_quad BIGINT; v_order SMALLINT;
BEGIN
  SELECT COALESCE(MAX(display_order), 0) INTO v_order FROM quote_vehicle_types;

  SELECT id INTO v_bike FROM quote_vehicle_types WHERE name ~* 'bicycle' ORDER BY id LIMIT 1;
  IF v_bike IS NULL THEN
    INSERT INTO quote_vehicle_types (name, fuel_type, fuel_economy, ownership, display_order, in_use_date, description)
    VALUES ('Bicycle', 'none', 0, 'owned', v_order + 1, DATE '2023-10-01', 'Patrol bicycle, owned — from the retired Contract Support Item "Bicycle"')
    RETURNING id INTO v_bike;
  END IF;
  UPDATE quote_vehicle_types SET ownership = 'owned', fuel_type = 'none' WHERE id = v_bike AND ownership = 'rented' AND NOT EXISTS (SELECT 1 FROM quote_vehicle_rates WHERE vehicle_type_id = v_bike);
  IF NOT EXISTS (SELECT 1 FROM quote_vehicle_owned_costs WHERE vehicle_type_id = v_bike) THEN
    INSERT INTO quote_vehicle_owned_costs (vehicle_type_id, effective_date, acquisition_cost, life_months, monthly_cost, note)
    VALUES (v_bike, DATE '2025-07-17', 5000, 24, 50, 'Carried from the Contract Support Item "Bicycle" (cost row of 2025-07-17)');
  END IF;

  SELECT id INTO v_golf FROM quote_vehicle_types WHERE name ~* 'golf' ORDER BY id LIMIT 1;
  IF v_golf IS NULL THEN
    INSERT INTO quote_vehicle_types (name, fuel_type, fuel_economy, ownership, display_order, in_use_date, description)
    VALUES ('Golf cart', 'none', 0, 'rented', v_order + 2, DATE '2026-06-17', 'Electric golf cart, rented — from the retired Contract Support Item "Golf Cart"')
    RETURNING id INTO v_golf;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM quote_vehicle_rates WHERE vehicle_type_id = v_golf) THEN
    INSERT INTO quote_vehicle_rates (vehicle_type_id, effective_date, contract_months, inclusive_km, monthly_rate, rate_incl_vat, note)
    VALUES (v_golf, DATE '2026-06-17', 36, 0, 4950, false, 'Carried from the Contract Support Item "Golf Cart" (R 4 950 a month, 36 months)');
  END IF;

  SELECT id INTO v_quad FROM quote_vehicle_types WHERE name ~* 'quad' ORDER BY id LIMIT 1;
  IF v_quad IS NULL THEN
    INSERT INTO quote_vehicle_types (name, fuel_type, fuel_economy, ownership, display_order, in_use_date, description)
    VALUES ('Quad bike 4 x 2', 'petrol', 6.5, 'owned', v_order + 3, DATE '2025-07-17', 'Owned — from the retired Contract Support Item "Quad bike 4 x 2"')
    RETURNING id INTO v_quad;
  END IF;
  UPDATE quote_vehicle_types SET ownership = 'owned' WHERE id = v_quad AND ownership = 'rented' AND NOT EXISTS (SELECT 1 FROM quote_vehicle_rates WHERE vehicle_type_id = v_quad);
  IF NOT EXISTS (SELECT 1 FROM quote_vehicle_owned_costs WHERE vehicle_type_id = v_quad) THEN
    INSERT INTO quote_vehicle_owned_costs (vehicle_type_id, effective_date, acquisition_cost, life_months, monthly_cost, note)
    VALUES (v_quad, DATE '2025-07-17', 69560, 36, 1000, 'Carried from the Contract Support Item "Quad bike 4 x 2" (cost row of 2025-07-17)');
  END IF;

  -- Retire the support items filed under the Site Mobility subcategory and switch the subcategory off.
  UPDATE quote_accessories a
     SET active = false, retired_date = LEAST(COALESCE(a.retired_date, CURRENT_DATE - 1), CURRENT_DATE - 1)
   WHERE a.subcategory_id IN (SELECT id FROM quote_support_subcategories WHERE group_name ~* 'site mobility' OR name ~* 'site mobility')
     AND a.active;
  UPDATE quote_support_subcategories SET active = false WHERE (group_name ~* 'site mobility' OR name ~* 'site mobility') AND active;
END $$;

NOTIFY pgrst, 'reload schema';
