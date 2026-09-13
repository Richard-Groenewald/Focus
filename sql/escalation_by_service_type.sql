-- Focus v7.9.46 — Annual escalation is specific to the service type (2026-09-13).
-- Idempotent. Run AFTER sql/revenue_stream_generator.sql. Dev first, then prod.
--
-- quote_annual_escalations gains service_major_id / service_sub_id. A row with
-- both NULL is the fallback for every service type; a row with the major set
-- covers that major (Manpower is edited as the horizontal band above the
-- Statutory Salary Rates grid); a row with the sub set is the most specific.
-- The Revenue Stream Generator picks sub → major → fallback for the start year.

BEGIN;

ALTER TABLE quote_annual_escalations
  ADD COLUMN IF NOT EXISTS service_major_id BIGINT REFERENCES service_major(id),
  ADD COLUMN IF NOT EXISTS service_sub_id   BIGINT REFERENCES service_sub(id);
ALTER TABLE quote_annual_escalations DROP CONSTRAINT IF EXISTS quote_annual_escalations_year_key;
CREATE UNIQUE INDEX IF NOT EXISTS ux_quote_annual_escalations_scope
  ON quote_annual_escalations (year, COALESCE(service_major_id, 0), COALESCE(service_sub_id, 0));

-- Manpower gets its own band, seeded from the fallback rows.
INSERT INTO quote_annual_escalations (year, escalation_pct, note, service_major_id)
SELECT g.year, g.escalation_pct, 'Seeded from the general default — set to the sectoral determination', m.id
FROM quote_annual_escalations g
JOIN service_major m ON m.name ILIKE '%manpower%'
WHERE g.service_major_id IS NULL AND g.service_sub_id IS NULL
  AND NOT EXISTS (SELECT 1 FROM quote_annual_escalations x WHERE x.year = g.year AND x.service_major_id = m.id AND x.service_sub_id IS NULL);

COMMIT;

-- Verification:
-- SELECT year, escalation_pct, service_major_id, service_sub_id FROM quote_annual_escalations ORDER BY service_major_id NULLS FIRST, service_sub_id NULLS FIRST, year;
