-- Focus v7.9.57 — Conditional Criteria → Support Items and Training (2026-09-17). Idempotent.
-- Run on BOTH databases, Test first. Run AFTER sql/support_item_conditions.sql.
--
-- Training courses join the Support Items conditions: a course may be a TRIGGER (kind
-- 'training', code = quote_training_courses.id as text — "firearm competency is ticked, so a
-- bullet-proof vest is required") and a TARGET ("the post is armed, so firearm competency is
-- required"). A course ticks on each post whose trigger is active; there is no contract-level
-- case for training. Like a support item, a course a condition ticked may be overridden off
-- with a reason: the tick row carries state 'off' and the reason. Existing rows keep state 'on'
-- (presence = ticked, as before), so nothing changes for quotes already captured.
--
-- Nothing here prices training; conditions only decide what is ticked.

BEGIN;

-- Overrides on the per-post training tick rows (as quote_post_accessories gained in v7.9.55).
ALTER TABLE quote_post_training
  ADD COLUMN IF NOT EXISTS state TEXT NOT NULL DEFAULT 'on' CHECK (state IN ('on','off')),
  ADD COLUMN IF NOT EXISTS override_reason TEXT;

-- 'training' becomes a member kind. The check was created unnamed in support_item_conditions.sql,
-- so it carries Postgres's generated name on both databases (verified 2026-09-17).
ALTER TABLE quote_support_item_rule_members
  DROP CONSTRAINT IF EXISTS quote_support_item_rule_members_kind_check;
ALTER TABLE quote_support_item_rule_members
  ADD CONSTRAINT quote_support_item_rule_members_kind_check
  CHECK (kind IN ('statutory','discretionary','incentive','post','support','training'));

COMMIT;

-- Verify:
--   SELECT column_name FROM information_schema.columns
--    WHERE table_name = 'quote_post_training' AND column_name IN ('state','override_reason');
--   SELECT pg_get_constraintdef(oid) FROM pg_constraint
--    WHERE conname = 'quote_support_item_rule_members_kind_check';
