-- Richard, 2026-11-19: "extensions can go above the stage maximum" — the ruling on the question
-- v7.9.96 left open. The v7.9.97 extension scale (stages.ext_probability / ext_min_probability /
-- ext_max_probability, read by stageScale) is the home: the three open stages take an extension
-- maximum of 100, so an extension's probability is never capped by its stage; entry figure and
-- minimum stay as the standard scale (blank = standard). Suspended, Secured and Lost are fixed
-- stages and are left alone. RUN ON DEV and PROD by Claude 2026-11-19 (attributed). Re-runnable;
-- the Stages admin page can change the figure per stage afterwards.
BEGIN;
SELECT set_config('request.headers', json_build_object(
  'x-actor-id', (SELECT id::text FROM people WHERE first_name = 'Claude' AND last_name = 'Code' ORDER BY id LIMIT 1),
  'x-real-actor-id', '1')::text, true);
UPDATE stages s SET ext_max_probability = 100
  FROM stage_categories c
 WHERE c.id = s.category_id AND c.name = 'Opportunity-Open'
   AND s.max_probability < 100 AND s.max_probability > 0
   AND (s.ext_max_probability IS NULL OR s.ext_max_probability < 100);
COMMIT;
