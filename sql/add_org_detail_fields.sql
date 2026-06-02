-- Organisation detail fields (identity/legal, B-BBEE, finance, addresses, comms,
-- relationship). Idempotent. Replaces the old free-text `address` column.

-- Identity & legal
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS account_no        text;
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS trading_name      text;
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS legal_form        text;
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS registration_no   text;
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS vat_no            text;
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS tax_reference_no  text;

-- B-BBEE
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS bbbee_level   text;
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS bbbee_expiry  date;

-- Finance
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS payment_terms text;
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS credit_limit  numeric;

-- Postal address
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS postal_line1 text;
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS postal_line2 text;
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS postal_line3 text;
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS postal_line4 text;
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS postal_code  text;

-- Physical address (+ province/country live here)
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS physical_line1 text;
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS physical_line2 text;
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS physical_line3 text;
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS physical_line4 text;
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS physical_code  text;
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS province       text;
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS country        text DEFAULT 'South Africa';

-- Comms
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS switchboard_tel text;
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS general_email   text;

-- Relationship
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS sector_id     bigint REFERENCES industry_sectors(id);
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS region_id     bigint REFERENCES regions(id);
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS parent_org_id bigint REFERENCES organisations(id);
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS client_since  date;

-- Migrate the old single-line address into Physical Address Line 1, then retire it.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'organisations' AND column_name = 'address'
  ) THEN
    UPDATE organisations
       SET physical_line1 = address
     WHERE address IS NOT NULL AND address <> ''
       AND (physical_line1 IS NULL OR physical_line1 = '');
    ALTER TABLE organisations DROP COLUMN address;
  END IF;
END $$;
