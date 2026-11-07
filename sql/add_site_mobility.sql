-- Site Mobility (Focus v7.10.30, Richard 2026-11-07: "build and push all" after the mock-up of the
-- proposed Site Mobility tab). Vehicles on a quote, priced the way the old Xone quote tool's
-- CalculateVehicle did: supplier rate for the km band and contract period + insurance + tracking
-- + fuel (km x economy x the fuel price as at the start date, wet only) + vehicle extras, marked up
-- (price = cost / (1 - markup)), plus excess km at the supplier's rate per km, not marked up.
--
-- Catalogues (Admin -> Proposal Builder -> Site Mobility, generic grids):
--   quote_vehicle_types   one row per vehicle type: fuel type and economy (l / 100 km)
--   quote_vehicle_rates   dated supplier quotes per type, km band and contract period
--   quote_fuel_prices     dated petrol / diesel prices per litre
--   quote_vehicle_extras  dated rows per extra (dash camera, light bar ...): a NEW row per price
--                         change, keyed by name like the discretionary allowances
-- Quote lines:
--   quote_vehicles             one line per vehicle type on the quote
--   quote_vehicle_extra_lines  the extras ticked on a line (extra_id) or typed ad hoc (name + amount)
--
-- Additive, re-runnable, SQL-editor safe. Run on BOTH databases with or before the code: a
-- database without these tables shows the Site Mobility tab empty and names this file.

BEGIN;

CREATE TABLE IF NOT EXISTS quote_vehicle_types (
  id              BIGSERIAL    PRIMARY KEY,
  name            TEXT         NOT NULL,
  fuel_type       TEXT         NOT NULL DEFAULT 'diesel' CHECK (fuel_type IN ('petrol','diesel')),
  fuel_economy    NUMERIC      NOT NULL DEFAULT 0 CHECK (fuel_economy >= 0),   -- litres per 100 km
  description     TEXT,
  display_order   SMALLINT,
  active          BOOLEAN      NOT NULL DEFAULT true,
  in_use_date     DATE,
  retired_date    DATE,
  created_by      BIGINT       REFERENCES people(id),
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS quote_vehicle_rates (
  id                 BIGSERIAL    PRIMARY KEY,
  vehicle_type_id    BIGINT       REFERENCES quote_vehicle_types(id) ON DELETE CASCADE,
  effective_date     DATE         NOT NULL DEFAULT CURRENT_DATE,
  contract_months    SMALLINT     NOT NULL DEFAULT 36 CHECK (contract_months > 0),
  inclusive_km       INTEGER      NOT NULL DEFAULT 0 CHECK (inclusive_km >= 0),
  monthly_rate       NUMERIC      NOT NULL DEFAULT 0 CHECK (monthly_rate >= 0),
  rate_incl_vat      BOOLEAN      NOT NULL DEFAULT false,   -- the typed rate includes VAT: it is stripped before pricing
  insurance_monthly  NUMERIC      NOT NULL DEFAULT 0 CHECK (insurance_monthly >= 0),
  tracking_monthly   NUMERIC      NOT NULL DEFAULT 0 CHECK (tracking_monthly >= 0),
  excess_km_rate     NUMERIC      NOT NULL DEFAULT 0 CHECK (excess_km_rate >= 0),
  supplier           TEXT,
  note               TEXT,
  created_by         BIGINT       REFERENCES people(id),
  created_at         TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS quote_vehicle_rates_type_idx ON quote_vehicle_rates (vehicle_type_id, effective_date);

CREATE TABLE IF NOT EXISTS quote_fuel_prices (
  id               BIGSERIAL    PRIMARY KEY,
  effective_date   DATE         NOT NULL DEFAULT CURRENT_DATE,
  fuel_type        TEXT         NOT NULL DEFAULT 'diesel' CHECK (fuel_type IN ('petrol','diesel')),
  price_per_litre  NUMERIC      NOT NULL DEFAULT 0 CHECK (price_per_litre >= 0),
  note             TEXT,
  created_by       BIGINT       REFERENCES people(id),
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS quote_vehicle_extras (
  id                 BIGSERIAL    PRIMARY KEY,
  name               TEXT         NOT NULL,
  effective_date     DATE         NOT NULL DEFAULT CURRENT_DATE,
  acquisition_cost   NUMERIC      NOT NULL DEFAULT 0 CHECK (acquisition_cost >= 0),
  life_months        SMALLINT     CHECK (life_months IS NULL OR life_months > 0),
  monthly_cost       NUMERIC      NOT NULL DEFAULT 0 CHECK (monthly_cost >= 0),   -- running cost per vehicle per month
  retired_date       DATE,
  display_order      SMALLINT,
  created_by         BIGINT       REFERENCES people(id),
  created_at         TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS quote_vehicles (
  id                 BIGSERIAL    PRIMARY KEY,
  quote_id           BIGINT       NOT NULL REFERENCES quote_quotes(id) ON DELETE CASCADE,
  vehicle_type_id    BIGINT       NOT NULL REFERENCES quote_vehicle_types(id),
  quantity           SMALLINT     NOT NULL DEFAULT 1 CHECK (quantity > 0),
  monthly_km         INTEGER      NOT NULL DEFAULT 0 CHECK (monthly_km >= 0),
  fuel_included      BOOLEAN      NOT NULL DEFAULT true,     -- wet (true) or dry (false)
  markup_pct         NUMERIC      CHECK (markup_pct IS NULL OR (markup_pct >= 0 AND markup_pct < 100)),   -- NULL = the quote's margin
  display_order      SMALLINT,
  note               TEXT,
  created_by         BIGINT       REFERENCES people(id),
  created_at         TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS quote_vehicles_quote_idx ON quote_vehicles (quote_id);

CREATE TABLE IF NOT EXISTS quote_vehicle_extra_lines (
  id                 BIGSERIAL    PRIMARY KEY,
  quote_vehicle_id   BIGINT       NOT NULL REFERENCES quote_vehicles(id) ON DELETE CASCADE,
  extra_id           BIGINT       REFERENCES quote_vehicle_extras(id),   -- NULL = an ad hoc extra typed on the line
  name               TEXT,
  monthly_amount     NUMERIC      CHECK (monthly_amount IS NULL OR monthly_amount >= 0),
  created_at         TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS quote_vehicle_extra_lines_vehicle_idx ON quote_vehicle_extra_lines (quote_vehicle_id);

-- Starting names only; rates, fuel prices and extra costs are Richard's to enter (nobody else knows
-- the real figures). A quote line on a type without a rate reads "no supplier rate" until then.
INSERT INTO quote_vehicle_types (name, fuel_type, fuel_economy, display_order, in_use_date)
SELECT v.name, v.fuel_type, v.fuel_economy, v.display_order, CURRENT_DATE
FROM (VALUES
  ('Light patrol car (1.0 - 1.2 hatchback)', 'petrol', 5.0, 1),
  ('Single cab bakkie (2.4 diesel)',         'diesel', 8.1, 2),
  ('Double cab bakkie (2.4 diesel)',         'diesel', 8.5, 3),
  ('14-seater staff transport',             'diesel', 9.8, 4),
  ('Quad bike (estate perimeter)',          'petrol', 6.5, 5)
) AS v(name, fuel_type, fuel_economy, display_order)
WHERE NOT EXISTS (SELECT 1 FROM quote_vehicle_types);

INSERT INTO quote_vehicle_extras (name, display_order)
SELECT e.name, e.display_order
FROM (VALUES ('Dash camera', 1), ('Roof light bar', 2), ('Two-way radio (vehicle)', 3), ('Branding', 4)) AS e(name, display_order)
WHERE NOT EXISTS (SELECT 1 FROM quote_vehicle_extras);

ALTER TABLE quote_vehicle_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE quote_vehicle_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE quote_fuel_prices ENABLE ROW LEVEL SECURITY;
ALTER TABLE quote_vehicle_extras ENABLE ROW LEVEL SECURITY;
ALTER TABLE quote_vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE quote_vehicle_extra_lines ENABLE ROW LEVEL SECURITY;
GRANT ALL ON quote_vehicle_types, quote_vehicle_rates, quote_fuel_prices, quote_vehicle_extras, quote_vehicles, quote_vehicle_extra_lines TO service_role;
GRANT USAGE, SELECT ON SEQUENCE quote_vehicle_types_id_seq, quote_vehicle_rates_id_seq, quote_fuel_prices_id_seq, quote_vehicle_extras_id_seq, quote_vehicles_id_seq, quote_vehicle_extra_lines_id_seq TO service_role;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['quote_vehicle_types', 'quote_vehicle_rates', 'quote_fuel_prices', 'quote_vehicle_extras', 'quote_vehicles', 'quote_vehicle_extra_lines'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_ins_' || t) THEN
      EXECUTE format('CREATE TRIGGER audit_ins_%1$I AFTER INSERT ON %1$I REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_upd_' || t) THEN
      EXECUTE format('CREATE TRIGGER audit_upd_%1$I AFTER UPDATE ON %1$I REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_del_' || t) THEN
      EXECUTE format('CREATE TRIGGER audit_del_%1$I AFTER DELETE ON %1$I REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
    END IF;
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';
COMMIT;
