-- One home per rule, phase 1 (v7.9.91), Richard 2026-10-02: "there seems to be multiple sources of
-- rules. Service categories, stages and proposal builder" -> "scope it, one home per rule" ->
-- "guarding 20, min 15. rest as proposed, start phase 1".
--
-- The homes:
--   SERVICE TYPE row (service_sub)  revenue type, margin default / minimum / maximum, default term.
--                                   max_margin is new; min_margin was stored but read by nothing;
--                                   is_recurring is the older duplicate of revenue_type and is now
--                                   kept in step with it (the form no longer shows it).
--   STAGE row (stages)              probability on entry, minimum, maximum.
--   SETTINGS                        the single values, all editable on the Settings page:
--                                   rsg_probability_cap (early-estimate probability, now also the
--                                   starting probability of an extension prospect),
--                                   default_margin_no_service, default_term_annuity,
--                                   default_term_project, proposal_vat_pct,
--                                   proposal_default_validity_days, proposal_xone_psira_no.
-- quote_opportunity_margin_rules is no longer read by v7.9.91 and its admin page is gone; the table
-- is left in place (v7.9.88-90 still read it) and can be dropped once every site runs v7.9.91.
--
-- Values = the table Richard approved on 2026-10-02 (Guarding 20 / min 15; the rest as proposed).
-- Re-runnable with one caveat (run it once per database): a service type is written only while its
-- max_margin is still NULL and a stage only while it still holds its old limit, so a re-run leaves a
-- later admin edit alone UNLESS the maximum was blanked again on the admin page (all four columns of
-- that service type are then rewritten to the values below) or Lost / In Progress / Complete was put
-- back to max 100 / min 0 (flipped again). Settings keys are inserted only where absent.
-- Run on DEV, then PROD, before or with the code. Attributed to Claude Code acting for Richard.
\set ON_ERROR_STOP on
BEGIN;
SELECT set_config('request.headers', json_build_object(
  'x-actor-id', (SELECT id::text FROM people WHERE first_name = 'Claude' AND last_name = 'Code' ORDER BY id LIMIT 1),
  'x-real-actor-id', '1')::text, true);

ALTER TABLE service_sub ADD COLUMN IF NOT EXISTS max_margin NUMERIC(5,2);

-- A. Per service type: default margin, minimum, maximum, default term (months).
UPDATE service_sub s
   SET default_margin = v.def, min_margin = v.min, max_margin = v.max, default_duration = v.term
  FROM (VALUES
    ('Guarding Services',           20::numeric, 15::numeric, 40::numeric, 12::int),
    ('On-site Control Room',        22,   20, 40, 12),
    ('Off-site Control Room',       25,   20, 40, 12),
    ('Maintenance Services',        30,   20, 40, 24),
    ('Project',                     25,   22, 45, NULL),
    ('Control Room Build',          25,   15, 45, 3),
    ('Control Room Upgrade',        25,   15, 45, 3),
    ('Control Room Design',         40,   15, 45, 1),
    ('Design Consulting',           40,   15, 45, 1),
    ('Risk Review',                 40,   15, 45, 1),
    ('Process Design & Definition', 40,   15, 45, 1),
    ('Business Analysis',           NULL, 30, 45, NULL)
  ) AS v(name, def, min, max, term)
 WHERE s.name = v.name AND s.max_margin IS NULL;

-- The Recurring flag follows the revenue type (one fact, one source).
UPDATE service_sub SET is_recurring = (revenue_type = 'annuity')
 WHERE is_recurring IS DISTINCT FROM (revenue_type = 'annuity');

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'service_sub_margin_band') THEN
    ALTER TABLE service_sub ADD CONSTRAINT service_sub_margin_band CHECK (
      (min_margin IS NULL OR max_margin IS NULL OR min_margin <= max_margin)
      AND (default_margin IS NULL OR (
            (min_margin IS NULL OR default_margin >= min_margin)
        AND (max_margin IS NULL OR default_margin <= max_margin))));
  END IF;
END $$;

-- B. Per stage: a lost deal holds 0%; a deal in fulfilment holds 100%.
UPDATE stages SET max_probability = 0   WHERE name = 'Lost' AND max_probability = 100;
UPDATE stages SET min_probability = 100 WHERE name IN ('In Progress', 'Complete') AND min_probability = 0;

-- C. Single values. New keys only where absent; the extension's own key is retired (the code
-- reads rsg_probability_cap for both; the old code's fallback for a missing key is the same 20).
INSERT INTO settings (key, value)
SELECT v.k, v.val FROM (VALUES ('default_margin_no_service', '25'), ('default_term_annuity', '12'), ('default_term_project', '3')) AS v(k, val)
 WHERE NOT EXISTS (SELECT 1 FROM settings s WHERE s.key = v.k);
DELETE FROM settings WHERE key = 'extension_initial_probability';

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Verify
SELECT sm.name AS family, ss.name, ss.revenue_type, ss.is_recurring, ss.default_margin, ss.min_margin, ss.max_margin, ss.default_duration
  FROM service_sub ss LEFT JOIN service_major sm ON sm.id = ss.major_id ORDER BY sm.name, ss.name;
SELECT name, probability, min_probability, max_probability FROM stages ORDER BY id;
SELECT key, value FROM settings WHERE key IN ('rsg_probability_cap', 'extension_initial_probability', 'default_margin_no_service',
  'default_term_annuity', 'default_term_project', 'proposal_vat_pct', 'proposal_default_validity_days', 'proposal_xone_psira_no',
  'escalation_month', 'fy_start_month') ORDER BY key;
