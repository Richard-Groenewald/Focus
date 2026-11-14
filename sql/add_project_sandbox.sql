-- Project planning, phase 3 (v7.10.34): plans on no deal — the Project Sandbox.
-- Richard 2026-11-13: "the creation of a project in the absence of a secured project, as part of the
-- proposal builder in opportunities, and perhaps also in a project sandbox".
--
-- A draft plan on an OPEN opportunity needs nothing here: it is the same project_plans row keyed on
-- the deal, tagged Draft by the client while the deal is unsecured. A SANDBOX plan has no deal:
-- deal_id becomes nullable and is_sandbox says what the row is. A plan has a deal or is a sandbox,
-- never neither. UNIQUE (deal_id) still holds one plan per deal — NULLs do not collide.
--
-- Additive, re-runnable, safe in the Supabase SQL editor. Run AFTER sql/add_project_plans.sql.

BEGIN;

ALTER TABLE project_plans ALTER COLUMN deal_id DROP NOT NULL;
ALTER TABLE project_plans ADD COLUMN IF NOT EXISTS is_sandbox BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE project_plans DROP CONSTRAINT IF EXISTS project_plans_deal_or_sandbox_chk;
ALTER TABLE project_plans ADD CONSTRAINT project_plans_deal_or_sandbox_chk
  CHECK ((deal_id IS NOT NULL AND is_sandbox = false) OR (deal_id IS NULL AND is_sandbox = true));

CREATE INDEX IF NOT EXISTS project_plans_sandbox_owner_idx ON project_plans (owner_id) WHERE is_sandbox;

COMMENT ON COLUMN project_plans.is_sandbox IS 'A practice plan on no deal (Project Management → Project Sandbox), the owner''s alone; never listed under Projects.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- Check rows (the SQL editor shows the last statement).
SELECT column_name, is_nullable, column_default
  FROM information_schema.columns
 WHERE table_name = 'project_plans' AND column_name IN ('deal_id', 'is_sandbox')
 ORDER BY column_name;
