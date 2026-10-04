-- Extension probability scale (v7.9.97), Richard 2026-10-04: "extensions should have their own
-- probability min/average/max scales".
--
-- A stage row already holds the probability scale for a deal at that stage: probability (the figure
-- on entry), min_probability, max_probability. It now holds a second scale for EXTENSION deals:
--   ext_probability      the extension's probability on entry at this stage
--   ext_min_probability  its minimum
--   ext_max_probability  its maximum (also the cap on its probability score)
-- Each is optional: NULL means "the same as the standard figure". So nothing changes until a value
-- is typed on Site Admin -> Lookups -> Stages.
--
-- One home per rule: the starting probability of a new extension prospect is now the first open
-- stage's ext_probability. The Settings value introduced by v7.9.96 (extension_initial_probability)
-- is carried onto the Prospect stage where it differs from the standard figure, and the key is
-- removed.
--
-- RUN ORDER: WITH or straight AFTER the v7.9.97 code - never ahead of it. The columns and the check
-- are additive, but the DELETE is not: the v7.9.96 code still reads extension_initial_probability
-- (and re-creates it on any Settings save), so removing it early would start new extensions at the
-- early-estimate figure. v7.9.97 runs correctly BEFORE this script: without the columns every
-- extension figure reads as the standard one and the old key is still honoured. Re-runnable.
-- The data changes are attributed to Claude Code acting for Richard.

\set ON_ERROR_STOP on
BEGIN;

SELECT set_config('request.headers', json_build_object(
  'x-actor-id', (SELECT id::text FROM people WHERE first_name = 'Claude' AND last_name = 'Code' ORDER BY id LIMIT 1),
  'x-real-actor-id', '1')::text, true);

ALTER TABLE stages
  ADD COLUMN IF NOT EXISTS ext_probability     INTEGER,
  ADD COLUMN IF NOT EXISTS ext_min_probability INTEGER,
  ADD COLUMN IF NOT EXISTS ext_max_probability INTEGER;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'stages_ext_probability_range') THEN
    ALTER TABLE stages ADD CONSTRAINT stages_ext_probability_range CHECK (
      (ext_probability     IS NULL OR (ext_probability     >= 0 AND ext_probability     <= 100)) AND
      (ext_min_probability IS NULL OR (ext_min_probability >= 0 AND ext_min_probability <= 100)) AND
      (ext_max_probability IS NULL OR (ext_max_probability >= 0 AND ext_max_probability <= 100)));
  END IF;
END $$;

-- The v7.9.96 Settings value becomes the Prospect stage's extension figure (only where it says
-- something the standard figure does not, and only while the stage has none of its own). The
-- extension maximum is raised, or the minimum lowered, ONLY when the carried figure falls outside
-- the stage's limit - otherwise they stay blank (= the standard figure). Then the key goes: the
-- stage row is the one home.
UPDATE stages s
SET ext_probability     = v.p,
    ext_max_probability = CASE WHEN v.p > COALESCE(s.ext_max_probability, s.max_probability, 100) THEN v.p ELSE s.ext_max_probability END,
    ext_min_probability = CASE WHEN v.p < COALESCE(s.ext_min_probability, s.min_probability, 0)   THEN v.p ELSE s.ext_min_probability END
FROM (SELECT round(value::numeric)::int AS p FROM settings
      WHERE key = 'extension_initial_probability' AND value ~ '^[0-9]+(\.[0-9]+)?$') v,
     stage_categories c
WHERE c.id = s.category_id AND c.name = 'Opportunity-Open' AND s.name = 'Prospect'
  AND s.ext_probability IS NULL AND v.p BETWEEN 0 AND 100
  AND v.p IS DISTINCT FROM s.probability;

DELETE FROM settings WHERE key = 'extension_initial_probability';

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Verify
SELECT s.name, s.probability AS on_entry, s.min_probability AS min, s.max_probability AS max,
       s.ext_probability AS ext_on_entry, s.ext_min_probability AS ext_min, s.ext_max_probability AS ext_max
FROM stages s JOIN stage_categories c ON c.id = s.category_id
ORDER BY c.id, s.sort_order;
