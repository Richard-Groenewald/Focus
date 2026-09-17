-- Focus v7.9.43 — Accessories and Training Courses: dated items and cost history
-- (2026-09-11). Idempotent. Dev first, then prod.
--
-- Each catalogue item now carries a window (in_use_date .. retired_date, both
-- inclusive; NULL = open) and a history of costs, one row per price change,
-- effective-dated the way quote_salary_rates and the statutory allowances
-- already are. The CURRENT cost is the newest row whose effective_date has
-- arrived, judged at the quote's contract start date (pbCurrentByCode in
-- index.html). Old rows are never edited, only superseded; each carries who
-- entered it and when, which is the audit trail.
--
-- The admin page generates `code` from the name on first save — it is the
-- stable key that survives a rename and is no longer typed by hand.

BEGIN;

ALTER TABLE quote_accessories
  ADD COLUMN IF NOT EXISTS in_use_date  DATE,
  ADD COLUMN IF NOT EXISTS retired_date DATE,
  ADD COLUMN IF NOT EXISTS description  TEXT,
  ADD COLUMN IF NOT EXISTS created_by   BIGINT REFERENCES people(id);

ALTER TABLE quote_training_courses
  ADD COLUMN IF NOT EXISTS in_use_date  DATE,
  ADD COLUMN IF NOT EXISTS retired_date DATE,
  ADD COLUMN IF NOT EXISTS description  TEXT,
  ADD COLUMN IF NOT EXISTS created_by   BIGINT REFERENCES people(id);

-- Existing rows: in use from the day the catalogue was seeded.
UPDATE quote_accessories      SET in_use_date = created_at::date WHERE in_use_date IS NULL;
UPDATE quote_training_courses SET in_use_date = created_at::date WHERE in_use_date IS NULL;

CREATE TABLE IF NOT EXISTS quote_accessory_costs (
  id             BIGSERIAL     PRIMARY KEY,
  accessory_id   BIGINT        NOT NULL REFERENCES quote_accessories(id) ON DELETE CASCADE,
  effective_date DATE          NOT NULL,
  unit_cost      NUMERIC(12,2) NOT NULL CHECK (unit_cost >= 0),
  cost_basis     TEXT          NOT NULL DEFAULT 'once_off_per_officer'
                               CHECK (cost_basis IN ('once_off_per_officer','once_off_per_post','monthly_per_officer','monthly_per_post')),
  note           TEXT,
  created_by     BIGINT        REFERENCES people(id),
  created_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),
  UNIQUE (accessory_id, effective_date)
);
CREATE INDEX IF NOT EXISTS idx_quote_accessory_costs_lookup ON quote_accessory_costs (accessory_id, effective_date DESC);

CREATE TABLE IF NOT EXISTS quote_training_costs (
  id                 BIGSERIAL     PRIMARY KEY,
  training_course_id BIGINT        NOT NULL REFERENCES quote_training_courses(id) ON DELETE CASCADE,
  effective_date     DATE          NOT NULL,
  cost_per_officer   NUMERIC(12,2) NOT NULL CHECK (cost_per_officer >= 0),
  validity_months    SMALLINT      CHECK (validity_months IS NULL OR validity_months > 0),   -- refresher cycle; NULL = once
  note               TEXT,
  created_by         BIGINT        REFERENCES people(id),
  created_at         TIMESTAMPTZ   NOT NULL DEFAULT now(),
  UNIQUE (training_course_id, effective_date)
);
CREATE INDEX IF NOT EXISTS idx_quote_training_costs_lookup ON quote_training_costs (training_course_id, effective_date DESC);

COMMIT;

-- Verification:
-- SELECT column_name FROM information_schema.columns WHERE table_name = 'quote_accessories' AND column_name IN ('in_use_date','retired_date');
-- SELECT 'acc_costs', count(*) FROM quote_accessory_costs UNION ALL SELECT 'trn_costs', count(*) FROM quote_training_costs;
