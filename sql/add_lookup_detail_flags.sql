-- Lookup rows that ask for more (Focus v7.10.12, Richard 2026-10-20: "under activity type lookup,
-- some activity types may prompt for further information to be captured. for instance 'other'
-- will require that you define other in a separate field").
--
-- v7.10.11 made "Other" (a next action) require Action Details by matching the row's NAME in the
-- code. This moves the rule onto the lookup row, one home per rule: any activity type or next
-- action can ask for a description, a rename never breaks it, and the row carries the prompt the
-- form shows.
--
--   activity_types.requires_detail   true → an engagement of this type must say what happened
--                                    (Engagement Details is required)
--   activity_types.detail_prompt     the prompt shown in that box while this type is picked
--   next_actions.requires_detail     true → an engagement with this next action must say what it
--                                    is (Action Details is required beside the due date)
--   next_actions.detail_prompt       the prompt shown in that box while this action is picked
--
-- Set under Site Admin → Lookups → Activity Types / Next Actions ("Requires a description" and
-- "Prompt shown to the user"). The client keeps the name match ("Other") as its fallback while
-- these columns are absent, so the code runs before or after this file.
--
-- Additive, re-runnable, no psql meta-commands (runs in the Supabase SQL editor). Flags the
-- next action named Other and the activity type named Other (Richard added that type on PROD on
-- 2026-10-20); nothing else is flagged — tick the rest on the lookup page.
-- Attributed to Claude Code acting for Richard.
--
-- SUPERSEDED the same day by sql/merge_engagement_lookups.sql (v7.10.13), which adds the same two
-- columns to activity_types and turns next_actions into a view: a database that never ran this file
-- needs only the merge file. The next_actions part below is skipped once next_actions is no longer
-- a table, so running this file after the merge is harmless.
BEGIN;

SELECT set_config('request.headers', json_build_object(
  'x-actor-id', (SELECT id::text FROM people WHERE first_name = 'Claude' AND last_name = 'Code' ORDER BY id LIMIT 1),
  'x-real-actor-id', '1')::text, true);

ALTER TABLE activity_types
  ADD COLUMN IF NOT EXISTS requires_detail BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS detail_prompt   TEXT;
COMMENT ON COLUMN activity_types.requires_detail IS 'An engagement of this type must carry Engagement Details (v7.10.12).';
COMMENT ON COLUMN activity_types.detail_prompt   IS 'Prompt shown in Engagement Details while this type is picked; blank = the standard wording.';

DO $$
BEGIN
  IF (SELECT c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relname = 'next_actions') = 'r' THEN
    ALTER TABLE next_actions
      ADD COLUMN IF NOT EXISTS requires_detail BOOLEAN NOT NULL DEFAULT false,
      ADD COLUMN IF NOT EXISTS detail_prompt   TEXT;
    COMMENT ON COLUMN next_actions.requires_detail IS 'An engagement with this next action must carry Action Details (v7.10.12).';
    COMMENT ON COLUMN next_actions.detail_prompt   IS 'Prompt shown in Action Details while this action is picked; blank = the standard wording.';
    -- "Other" keeps the v7.10.11 rule, now as data. Only a row still unflagged is touched, so a
    -- later change on the lookup page survives a re-run.
    UPDATE next_actions
       SET requires_detail = true,
           detail_prompt   = COALESCE(NULLIF(trim(detail_prompt), ''), 'Say what the next action is')
     WHERE lower(trim(name)) = 'other' AND requires_detail = false;
  END IF;
END $$;

-- An activity type named Other asks what the engagement was, the same way.
UPDATE activity_types
   SET requires_detail = true,
       detail_prompt   = COALESCE(NULLIF(trim(detail_prompt), ''), 'Say what the engagement was')
 WHERE lower(trim(name)) = 'other' AND requires_detail = false;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Verification:
-- SELECT 'activity_types' t, name, requires_detail, detail_prompt FROM activity_types
-- UNION ALL SELECT 'next_actions', name, requires_detail, detail_prompt FROM next_actions ORDER BY 1, 2;
