-- Project planning, phase 2: the Schedule view — MS Project-style task grid, Gantt and PERT
-- (Focus v7.10.33, Richard 2026-11-13: "would like an interface similar to MS Project? and have
-- gantt and pert charts" → "do it").
--
-- Adds to the phase 1 tables (sql/add_project_plans.sql):
--   project_tasks        duration_days (working days, Mon–Fri less public_holidays), pct_done,
--                        constraint_type asap | must_start_on (a pinned start), slack_days (computed
--                        by the client's scheduling engine and stored so lists can read it),
--                        the three-point PERT estimate (pert_optimistic / pert_likely / pert_pessimistic)
--                        and the baseline (baseline_start / baseline_end)
--   project_plans        baseline_set_at, baseline_set_by
--   project_task_links   one row per dependency: from_task → to_task, link_type FS | SS | FF | SF,
--                        lag_days (working days, may be negative); never a self-link, never a
--                        duplicate pair; a cycle is refused by trigger
-- Dates themselves stay on project_tasks.start_date / due_date: the engine writes them, so every
-- phase 1 reader (list, board, health, the Projects page) sees the scheduled dates.
--
-- Additive, re-runnable, SQL-editor safe. Run on DEV first, then PROD, with or before the code:
-- a database without the links table shows the Schedule view with predecessors switched off.

BEGIN;

ALTER TABLE project_tasks ADD COLUMN IF NOT EXISTS duration_days    INTEGER CHECK (duration_days IS NULL OR duration_days >= 0);
ALTER TABLE project_tasks ADD COLUMN IF NOT EXISTS pct_done         INTEGER NOT NULL DEFAULT 0 CHECK (pct_done >= 0 AND pct_done <= 100);
ALTER TABLE project_tasks ADD COLUMN IF NOT EXISTS constraint_type  TEXT NOT NULL DEFAULT 'asap' CHECK (constraint_type IN ('asap', 'must_start_on'));
ALTER TABLE project_tasks ADD COLUMN IF NOT EXISTS slack_days       INTEGER;
ALTER TABLE project_tasks ADD COLUMN IF NOT EXISTS pert_optimistic  NUMERIC(8,2) CHECK (pert_optimistic IS NULL OR pert_optimistic >= 0);
ALTER TABLE project_tasks ADD COLUMN IF NOT EXISTS pert_likely      NUMERIC(8,2) CHECK (pert_likely IS NULL OR pert_likely >= 0);
ALTER TABLE project_tasks ADD COLUMN IF NOT EXISTS pert_pessimistic NUMERIC(8,2) CHECK (pert_pessimistic IS NULL OR pert_pessimistic >= 0);
ALTER TABLE project_tasks ADD COLUMN IF NOT EXISTS baseline_start   DATE;
ALTER TABLE project_tasks ADD COLUMN IF NOT EXISTS baseline_end     DATE;

ALTER TABLE project_plans ADD COLUMN IF NOT EXISTS baseline_set_at TIMESTAMPTZ;
ALTER TABLE project_plans ADD COLUMN IF NOT EXISTS baseline_set_by BIGINT REFERENCES people(id);

CREATE TABLE IF NOT EXISTS project_task_links (
  id         BIGSERIAL PRIMARY KEY,
  plan_id    BIGINT NOT NULL REFERENCES project_plans(id) ON DELETE CASCADE,
  from_task  BIGINT NOT NULL REFERENCES project_tasks(id) ON DELETE CASCADE,   -- the predecessor
  to_task    BIGINT NOT NULL REFERENCES project_tasks(id) ON DELETE CASCADE,   -- the successor
  link_type  TEXT NOT NULL DEFAULT 'FS' CHECK (link_type IN ('FS', 'SS', 'FF', 'SF')),
  lag_days   INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by BIGINT REFERENCES people(id),
  CONSTRAINT project_task_links_not_self CHECK (from_task <> to_task),
  UNIQUE (from_task, to_task)
);
CREATE INDEX IF NOT EXISTS project_task_links_plan_idx ON project_task_links (plan_id);
CREATE INDEX IF NOT EXISTS project_task_links_to_idx   ON project_task_links (to_task);

-- A link may not close a loop: walking the successors of to_task must never reach from_task.
CREATE OR REPLACE FUNCTION project_task_links_no_cycle() RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF EXISTS (
    WITH RECURSIVE walk(task) AS (
      SELECT NEW.to_task
      UNION
      SELECT l.to_task FROM project_task_links l JOIN walk w ON l.from_task = w.task
    )
    SELECT 1 FROM walk WHERE task = NEW.from_task
  ) THEN
    RAISE EXCEPTION 'That link would make a loop: the successor already leads back to the predecessor';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_project_task_links_no_cycle ON project_task_links;
CREATE TRIGGER trg_project_task_links_no_cycle BEFORE INSERT OR UPDATE ON project_task_links
  FOR EACH ROW EXECUTE FUNCTION project_task_links_no_cycle();

ALTER TABLE project_task_links ENABLE ROW LEVEL SECURITY;
GRANT ALL ON project_task_links TO service_role;
GRANT USAGE, SELECT ON SEQUENCE project_task_links_id_seq TO service_role;

DO $$
DECLARE t text := 'project_task_links';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_ins_' || t) THEN
    EXECUTE format('CREATE TRIGGER audit_ins_%1$I AFTER INSERT ON %1$I REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_upd_' || t) THEN
    EXECUTE format('CREATE TRIGGER audit_upd_%1$I AFTER UPDATE ON %1$I REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_del_' || t) THEN
    EXECUTE format('CREATE TRIGGER audit_del_%1$I AFTER DELETE ON %1$I REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
COMMIT;
