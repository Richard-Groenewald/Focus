-- Next action "Note" becomes "Other" (Focus v7.10.11, Richard 2026-10-19: "under lead engagements,
-- there is a next action called 'Note'. This is not an action item. Replace it with 'Other', change
-- all in both prod and dev database").
--
-- "Note" was seeded 2026-05-22 with the original defaults and retired by sql/retire_note_add_nfa.sql
-- (v7.8.85) because it was an escape hatch from the mandatory next action. "Other" is the honest
-- catch-all: the client (v7.10.11) refuses to save it without a description in Action Details, so
-- an "Other" is always a named obligation with a due date.
--
-- What this does, on whichever state the database is in:
--   1. next_actions: the row named "Note" is RENAMED "Other" (same id, so every engagement's
--      next_action_id keeps pointing at it), switched on, offered on leads (its opportunities
--      flag is left as it was). If an "Other" row already exists, "Note" is retired instead and
--      the engagements that point at it are re-pointed at "Other". A database with neither gets
--      a fresh "Other" row.
--   2. engagements: every row whose next_action text reads "Note" now reads "Other" (the lists,
--      Outstanding Actions and the dashboard print that text), and next_action_id follows.
--   3. leads: the same for leads.next_action (the trigger copies the latest engagement's next
--      action onto the lead).
-- Idempotent — a re-run changes nothing. Run on BOTH databases (DEV, then PROD). Runs in the
-- Supabase SQL editor or psql: no psql meta-commands. Attributed to Claude Code acting for Richard.
BEGIN;

SELECT set_config('request.headers', json_build_object(
  'x-actor-id', (SELECT id::text FROM people WHERE first_name = 'Claude' AND last_name = 'Code' ORDER BY id LIMIT 1),
  'x-real-actor-id', '1')::text, true);

DO $$
DECLARE
  v_other BIGINT;
  v_note  BIGINT;
BEGIN
  SELECT id INTO v_other FROM next_actions WHERE lower(trim(name)) = 'other' ORDER BY active DESC, id LIMIT 1;
  SELECT id INTO v_note  FROM next_actions WHERE lower(trim(name)) = 'note'  ORDER BY active DESC, id LIMIT 1;

  IF v_other IS NULL AND v_note IS NOT NULL THEN
    -- 1a. Rename in place: the id stays, so next_action_id references hold.
    UPDATE next_actions
       SET name = 'Other',
           description = 'Any other next action — say what it is in Action Details (required) and when it is due',
           active = true,
           applies_to_leads = true,
           updated_at = now()
     WHERE id = v_note;
    v_other := v_note;
  ELSIF v_other IS NULL THEN
    -- 1c. Neither row exists: a fresh "Other".
    INSERT INTO next_actions (name, description, active, sort_order, applies_to_opportunities, applies_to_leads)
    VALUES ('Other', 'Any other next action — say what it is in Action Details (required) and when it is due', true, 60, true, true)
    RETURNING id INTO v_other;
  ELSE
    -- 1b. "Other" already exists: make sure it is on and offered on leads.
    UPDATE next_actions SET active = true, applies_to_leads = true, updated_at = now()
     WHERE id = v_other AND (active = false OR applies_to_leads = false);
  END IF;

  -- Any remaining "Note" rows (a second one, or the one left when "Other" already existed) are retired
  -- and everything pointing at them moves to "Other".
  UPDATE engagements SET next_action_id = v_other
   WHERE next_action_id IN (SELECT id FROM next_actions WHERE lower(trim(name)) = 'note');
  UPDATE next_actions SET active = false, updated_at = now()
   WHERE lower(trim(name)) = 'note' AND active = true;

  -- 2. The text the lists print.
  UPDATE engagements SET next_action = 'Other' WHERE next_action = 'Note';

  -- 3. The lead's own copy of its current next action.
  UPDATE leads SET next_action = 'Other' WHERE next_action = 'Note';
END $$;

COMMIT;

-- Verification (expected: no row named Note that is active; one Other; zero engagements or leads reading Note):
-- SELECT id, name, active, sort_order, applies_to_leads, applies_to_opportunities FROM next_actions ORDER BY active DESC, sort_order NULLS LAST, id;
-- SELECT count(*) AS eng_note FROM engagements WHERE next_action = 'Note';
-- SELECT count(*) AS lead_note FROM leads WHERE next_action = 'Note';
-- SELECT count(*) AS eng_other FROM engagements WHERE next_action = 'Other';
