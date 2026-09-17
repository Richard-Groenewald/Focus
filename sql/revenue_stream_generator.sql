-- Focus v7.9.45 — Revenue Stream Generator (2026-09-13). Idempotent. Dev first, then prod.
--
-- The Proposal Builder tab's top block becomes the Revenue Stream Generator:
-- a collapsed panel that builds an opportunity's revenue stream before a
-- proposal exists, capped at a low probability. It needs three admin-coded
-- things:
--   1. service_sub.revenue_type   'annuity' | 'project' — which generator a
--                                 service type gets (seeded from is_recurring).
--   2. quote_annual_escalations   one row per year: the default annual
--                                 escalation % for a stream starting that year
--                                 (Admin → Proposal Builder → Human Resources).
--   3. quote_opportunity_margin_rules  effective-dated min / default / max margin
--                                 per revenue type, optionally per service type
--                                 (Admin → Proposal Builder → Opportunity Margin Rules).
--   plus the settings row rsg_probability_cap (default 20).

BEGIN;

ALTER TABLE service_sub ADD COLUMN IF NOT EXISTS revenue_type TEXT NOT NULL DEFAULT 'annuity';
ALTER TABLE service_sub DROP CONSTRAINT IF EXISTS service_sub_revenue_type_check;
ALTER TABLE service_sub ADD CONSTRAINT service_sub_revenue_type_check CHECK (revenue_type IN ('annuity','project'));
UPDATE service_sub SET revenue_type = 'project' WHERE is_recurring = false AND revenue_type = 'annuity';

CREATE TABLE IF NOT EXISTS quote_annual_escalations (
  id             BIGSERIAL    PRIMARY KEY,
  year           INTEGER      NOT NULL UNIQUE CHECK (year BETWEEN 2000 AND 2100),
  escalation_pct NUMERIC(5,2) NOT NULL CHECK (escalation_pct >= 0),
  note           TEXT,
  created_by     BIGINT       REFERENCES people(id),
  created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);
INSERT INTO quote_annual_escalations (year, escalation_pct, note)
SELECT y, 6.00, 'Seeded default — adjust to the PSIRA / sectoral determination'
FROM generate_series(2025, 2030) AS y
ON CONFLICT (year) DO NOTHING;

CREATE TABLE IF NOT EXISTS quote_opportunity_margin_rules (
  id                 BIGSERIAL    PRIMARY KEY,
  effective_date     DATE         NOT NULL DEFAULT CURRENT_DATE,
  revenue_type       TEXT         NOT NULL DEFAULT 'annuity' CHECK (revenue_type IN ('annuity','project')),
  service_sub_id     BIGINT       REFERENCES service_sub(id),          -- NULL = every service type of that revenue type
  min_margin_pct     NUMERIC(5,2) NOT NULL DEFAULT 0  CHECK (min_margin_pct >= 0),
  default_margin_pct NUMERIC(5,2) NOT NULL DEFAULT 25 CHECK (default_margin_pct >= 0),
  max_margin_pct     NUMERIC(5,2) NOT NULL DEFAULT 100 CHECK (max_margin_pct >= 0),
  active             BOOLEAN      NOT NULL DEFAULT true,
  note               TEXT,
  created_by         BIGINT       REFERENCES people(id),
  created_at         TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ  NOT NULL DEFAULT now(),
  CHECK (min_margin_pct <= default_margin_pct AND default_margin_pct <= max_margin_pct)
);
CREATE INDEX IF NOT EXISTS idx_quote_opp_margin_rules_lookup
  ON quote_opportunity_margin_rules (revenue_type, service_sub_id, effective_date DESC);
INSERT INTO quote_opportunity_margin_rules (effective_date, revenue_type, service_sub_id, min_margin_pct, default_margin_pct, max_margin_pct, note)
SELECT '2025-01-01', v.rt, NULL, v.mn, v.df, v.mx, 'Seeded default — refine per service type'
FROM (VALUES ('annuity', 20.00, 25.00, 40.00), ('project', 15.00, 25.00, 45.00)) AS v(rt, mn, df, mx)
WHERE NOT EXISTS (SELECT 1 FROM quote_opportunity_margin_rules r WHERE r.revenue_type = v.rt AND r.service_sub_id IS NULL);

INSERT INTO settings (key, value) VALUES ('rsg_probability_cap', '20') ON CONFLICT (key) DO NOTHING;

COMMIT;

-- Verification:
-- SELECT revenue_type, count(*) FROM service_sub GROUP BY 1;
-- SELECT year, escalation_pct FROM quote_annual_escalations ORDER BY year;
-- SELECT revenue_type, min_margin_pct, default_margin_pct, max_margin_pct FROM quote_opportunity_margin_rules;
