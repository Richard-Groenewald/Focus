-- Uniform Types + costs (Focus v7.9.65, Richard 2026-09-18: "uniform is
-- individual, and common per post... use that column for a uniform dropdown",
-- then "uniforms have costs and these should be managed under proposal
-- builder similar to workforce support items"). Supersedes the earlier
-- same-night draft of this file (v7.9.64) -- nothing from that draft has been
-- deployed anywhere, so this is a clean rewrite, not a follow-up migration.
--
-- Uniform stays its OWN table (a post picks exactly one uniform type via a
-- dropdown -- quote_posts.uniform_id -- never the multi-tick checklist
-- Workforce Support Items use), but reuses the SAME cost-history shape and
-- the SAME generic PB_ITEM_KINDS admin machinery that already serves
-- Accessories and Training Courses: quote_uniform_type_costs mirrors
-- quote_accessory_costs exactly, so pbItemCurrentCost / pbAccMonthlyUnit /
-- pbAccQtyForPost / the whole cost-drawer admin UI apply to it unchanged.
-- Idempotent; run on BOTH databases before the code.

BEGIN;

CREATE TABLE IF NOT EXISTS quote_uniform_types (
  id            BIGSERIAL    PRIMARY KEY,
  code          TEXT         UNIQUE,
  name          TEXT         NOT NULL,
  display_order SMALLINT,
  active        BOOLEAN      NOT NULL DEFAULT true,
  in_use_date   DATE,
  retired_date  DATE,
  description   TEXT,
  created_by    BIGINT       REFERENCES people(id),
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS quote_uniform_type_costs (
  id                 BIGSERIAL    PRIMARY KEY,
  uniform_type_id    BIGINT       NOT NULL REFERENCES quote_uniform_types(id) ON DELETE CASCADE,
  effective_date     DATE         NOT NULL,
  acquisition_cost   NUMERIC      NOT NULL DEFAULT 0 CHECK (acquisition_cost >= 0),
  life_months        SMALLINT     CHECK (life_months IS NULL OR life_months > 0),
  monthly_cost       NUMERIC      NOT NULL DEFAULT 0 CHECK (monthly_cost >= 0),
  loss_pct_per_year  NUMERIC      NOT NULL DEFAULT 0 CHECK (loss_pct_per_year >= 0),
  cost_basis         TEXT         NOT NULL DEFAULT 'per_officer' CHECK (cost_basis IN ('per_officer','per_duty_position','per_post','per_contract')),
  recovery           TEXT         NOT NULL DEFAULT 'amortised' CHECK (recovery IN ('amortised','once_off','absorbed')),
  note               TEXT,
  created_by         BIGINT       REFERENCES people(id),
  created_at         TIMESTAMPTZ  NOT NULL DEFAULT now(),
  UNIQUE (uniform_type_id, effective_date)
);

ALTER TABLE quote_posts ADD COLUMN IF NOT EXISTS uniform_id BIGINT REFERENCES quote_uniform_types(id);
ALTER TABLE quote_posts DROP COLUMN IF EXISTS uniform;   -- the old free-text column: never wired to any input, zero rows

-- A short starting list -- names only, no cost seeded (nobody but Richard
-- knows the real prices; "no cost yet" is the honest state until he adds the
-- first cost from Proposal Builder -> Uniform Types). His to rename, reorder,
-- retire or add to.
INSERT INTO quote_uniform_types (code, name, display_order, in_use_date) VALUES
  ('standard',        'Standard',                    1, CURRENT_DATE),
  ('formal_no1',      'Formal / No.1 Dress',          2, CURRENT_DATE),
  ('tactical',         'Tactical / Response',         3, CURRENT_DATE),
  ('reception',        'Reception / Front of House',  4, CURRENT_DATE)
ON CONFLICT (code) DO NOTHING;

ALTER TABLE quote_uniform_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE quote_uniform_type_costs ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['quote_uniform_types', 'quote_uniform_type_costs'] LOOP
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

COMMIT;

-- Verify
SELECT id, code, name, active, in_use_date, retired_date FROM quote_uniform_types ORDER BY display_order;
SELECT count(*) AS cost_rows_seeded_should_be_0 FROM quote_uniform_type_costs;
SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'quote_posts' AND column_name IN ('uniform', 'uniform_id');
SELECT tablename, rowsecurity FROM pg_tables WHERE tablename IN ('quote_uniform_types', 'quote_uniform_type_costs');
SELECT tgrelid::regclass::text AS tbl, tgname FROM pg_trigger WHERE tgrelid IN ('quote_uniform_types'::regclass, 'quote_uniform_type_costs'::regclass) AND NOT tgisinternal ORDER BY 1, 2;
