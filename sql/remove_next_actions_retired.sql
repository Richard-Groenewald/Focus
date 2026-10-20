-- Removes the table the v7.10.13 merge retired (sql/merge_engagement_lookups.sql renamed the old
-- next_actions table to next_actions_retired and kept it, rows and map column included, so the
-- merge could be checked or reversed). Run this ONLY once the release has settled and nothing needs
-- the old rows — it cannot be undone. Paste into the Supabase SQL editor; re-runnable.
-- Attributed to Claude Code acting for Richard; the statement-level audit on the table goes with it.
BEGIN;
SELECT set_config('request.headers', json_build_object(
  'x-actor-id', (SELECT id::text FROM people WHERE first_name = 'Claude' AND last_name = 'Code' ORDER BY id LIMIT 1),
  'x-real-actor-id', '1')::text, true);
DROP TABLE IF EXISTS next_actions_retired;
COMMIT;
NOTIFY pgrst, 'reload schema';
