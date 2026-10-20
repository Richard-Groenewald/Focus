-- One lookup for engagement types and next actions (Focus v7.10.13, Richard 2026-10-20: "in leads we
-- have type under engagement and type under follow up.... should these be the same and come from the
-- same setup?" → "merge and build on dev and prod").
--
-- Until now `activity_types` fed the engagement form's Type and `next_actions` its Next Action — two
-- tables, near-copies of each other, edited separately (LinkedIn Message was added to both by hand).
-- From here `activity_types` is the ONE list. Each row says where it is offered:
--   use_as_type          offered as an engagement type (what happened)
--   use_as_next_action   offered as a next action (what is owed next)
-- beside the existing applies_to_leads / applies_to_opportunities scope and the v7.10.12 detail flag
-- (requires_detail + detail_prompt), which now applies to whichever use the row is picked for — with
-- a blank prompt the form uses its standard wording for that use.
--
-- What this file does, ONCE (the merge block runs only while next_actions is still a TABLE):
--   1. adds the two use columns (and the v7.10.12 detail columns where a database lacks them);
--   2. for every next_actions row: a same-named activity type takes the next-action use (its scope,
--      active state and detail flag become the union of the two rows); a next action with no namesake
--      (No Further Action; Other where no such type exists) becomes a new activity_types row offered
--      as a next action only. Each old row records the activity_types id it became in `merged_into`;
--   3. re-points engagements.next_action_id from next_actions ids to activity_types ids — the names
--      matched but the ids did not (Other is next_actions 7 while activity_types 7 is Note);
--   4. RENAMES the old table to `next_actions_retired` (rows, sequence, triggers and `merged_into`
--      kept, so the merge can be read back or reversed) and leaves a read-only compatibility VIEW
--      named next_actions over activity_types (the use_as_next_action rows), so a browser still
--      running the previous release keeps reading its list until it reloads; nothing writes to it.
--      Remove next_actions_retired once the release has settled: sql/remove_next_actions_retired.sql;
--   5. a row named Other asks for a description (the v7.10.11 / v7.10.12 rule as data) with no fixed
--      prompt, so each use gets its standard wording.
-- Re-runnable, SQL-editor safe (no psql meta-commands), attributed to Claude Code acting for Richard.
-- The code (v7.10.13) runs before or after this file: without the columns it reads the two old lists.
BEGIN;

SELECT set_config('request.headers', json_build_object(
  'x-actor-id', (SELECT id::text FROM people WHERE first_name = 'Claude' AND last_name = 'Code' ORDER BY id LIMIT 1),
  'x-real-actor-id', '1')::text, true);

-- 1. The columns.
ALTER TABLE activity_types
  ADD COLUMN IF NOT EXISTS requires_detail    BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS detail_prompt      TEXT,
  ADD COLUMN IF NOT EXISTS use_as_type        BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS use_as_next_action BOOLEAN NOT NULL DEFAULT false;
COMMENT ON COLUMN activity_types.use_as_type        IS 'Offered as an engagement type — what happened (v7.10.13: one list for types and next actions).';
COMMENT ON COLUMN activity_types.use_as_next_action IS 'Offered as a next action — what is owed next (v7.10.13).';
COMMENT ON COLUMN activity_types.requires_detail    IS 'A pick of this row must carry a description: Engagement Details as a type, Action Details as a next action (v7.10.12).';
COMMENT ON COLUMN activity_types.detail_prompt      IS 'Prompt shown in that box while this row is picked; blank = the standard wording for the use.';

-- 2–4. The merge, once.
DO $$
DECLARE
  v_kind  "char";
  v_new   bigint;
  v_moved integer;
  r       record;
BEGIN
  SELECT c.relkind INTO v_kind
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relname = 'next_actions';
  IF v_kind IS DISTINCT FROM 'r' THEN
    RAISE NOTICE 'next_actions is % here — the merge has already run', COALESCE('relkind ' || v_kind::text, 'absent');
    RETURN;
  END IF;

  -- The detail columns on the old table too, for a database that never ran sql/add_lookup_detail_flags.sql,
  -- and the map column: the activity_types id each old row became.
  ALTER TABLE next_actions
    ADD COLUMN IF NOT EXISTS requires_detail BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS detail_prompt   TEXT,
    ADD COLUMN IF NOT EXISTS merged_into     BIGINT;
  COMMENT ON COLUMN next_actions.merged_into IS 'v7.10.13 merge: the activity_types row this next action became.';

  -- The map, by name (case and spaces aside): a same-named activity type, where one exists.
  UPDATE next_actions na
     SET merged_into = (SELECT a.id FROM activity_types a WHERE lower(trim(a.name)) = lower(trim(na.name)) ORDER BY a.id LIMIT 1);

  -- a) A same-named type takes the next-action use. use_as_type keeps what the type offered until now
  --    (an inactive type stays unoffered as a type even when its namesake action was live); scope,
  --    active and the detail flag are the union; a prompt set on either side is kept.
  UPDATE activity_types a
     SET use_as_type              = a.active,
         use_as_next_action       = na.active,
         applies_to_leads         = a.applies_to_leads OR na.applies_to_leads,
         applies_to_opportunities = a.applies_to_opportunities OR na.applies_to_opportunities,
         active                   = a.active OR na.active,
         requires_detail          = a.requires_detail OR na.requires_detail,
         detail_prompt            = COALESCE(NULLIF(trim(a.detail_prompt), ''), NULLIF(trim(na.detail_prompt), '')),
         updated_at               = now()
    FROM next_actions na
   WHERE na.merged_into = a.id;

  -- b) A next action with no namesake becomes a next-action-only row (one per name).
  FOR r IN SELECT * FROM next_actions WHERE merged_into IS NULL ORDER BY id LOOP
    SELECT a.id INTO v_new FROM activity_types a WHERE lower(trim(a.name)) = lower(trim(r.name)) ORDER BY a.id LIMIT 1;
    IF v_new IS NULL THEN
      INSERT INTO activity_types (name, description, applies_to_opportunities, applies_to_leads, active, sort_order,
                                  requires_detail, detail_prompt, use_as_type, use_as_next_action, created_at, updated_at)
      VALUES (r.name, r.description, r.applies_to_opportunities, r.applies_to_leads, r.active, r.sort_order,
              r.requires_detail, NULLIF(trim(r.detail_prompt), ''), false, true, COALESCE(r.created_at, now()), now())
      RETURNING id INTO v_new;
    END IF;
    UPDATE next_actions SET merged_into = v_new WHERE id = r.id;
  END LOOP;

  -- 3. Re-point the engagements (one statement over the OLD ids, so a value is never mapped twice).
  ALTER TABLE engagements DROP CONSTRAINT IF EXISTS engagements_next_action_id_fkey;
  UPDATE engagements e
     SET next_action_id = na.merged_into
    FROM next_actions na
   WHERE e.next_action_id = na.id AND e.next_action_id IS DISTINCT FROM na.merged_into;
  GET DIAGNOSTICS v_moved = ROW_COUNT;
  RAISE NOTICE 'engagements re-pointed to activity_types ids: %', v_moved;
  ALTER TABLE engagements
    ADD CONSTRAINT engagements_next_action_id_fkey FOREIGN KEY (next_action_id) REFERENCES activity_types(id);

  -- 4. The old table is retired under another name (nothing reads or writes it; the view takes its name).
  ALTER TABLE next_actions RENAME TO next_actions_retired;
  COMMENT ON TABLE next_actions_retired IS 'Retired by the v7.10.13 merge (2026-10-20): next actions live in activity_types (use_as_next_action); merged_into maps each old row. Kept for reference until removed by sql/remove_next_actions_retired.sql.';
END $$;

-- The compatibility view: the previous release's browsers read `next_actions` until they reload.
CREATE OR REPLACE VIEW next_actions AS
  SELECT id, name, description, applies_to_opportunities, applies_to_leads, active, sort_order,
         created_at, updated_at, requires_detail, detail_prompt
    FROM activity_types
   WHERE use_as_next_action;
COMMENT ON VIEW next_actions IS 'Compatibility view (v7.10.13): next actions are activity_types rows with use_as_next_action. Read-only; remove once nothing reads it.';
GRANT SELECT ON next_actions TO service_role;

-- A row is offered as something: a type, a next action, or both (Active switches a row off entirely).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'activity_types_use_check' AND conrelid = 'activity_types'::regclass) THEN
    ALTER TABLE activity_types ADD CONSTRAINT activity_types_use_check CHECK (use_as_type OR use_as_next_action);
  END IF;
END $$;

-- 5. Other asks for a description, with the standard wording for each use (the canned v7.10.12 prompts
--    were written for one use each; a blank prompt lets the form say the right thing for either).
UPDATE activity_types
   SET requires_detail = true, updated_at = now()
 WHERE lower(trim(name)) = 'other' AND requires_detail = false;
UPDATE activity_types
   SET detail_prompt = NULL, updated_at = now()
 WHERE lower(trim(name)) = 'other' AND detail_prompt IN ('Say what the next action is', 'Say what the engagement was');

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Verification:
-- SELECT id, name, use_as_type AS type, use_as_next_action AS next_action, applies_to_leads AS leads,
--        applies_to_opportunities AS opps, active, requires_detail, detail_prompt, sort_order
--   FROM activity_types ORDER BY sort_order NULLS LAST, name;
-- Every engagement's next-action text names the row its id points at:
-- SELECT e.next_action, a.name AS row_name, count(*) FROM engagements e
--   LEFT JOIN activity_types a ON a.id = e.next_action_id GROUP BY 1, 2 ORDER BY 1, 2;
-- The map the merge made:
-- SELECT id AS old_id, name, merged_into FROM next_actions_retired ORDER BY id;
