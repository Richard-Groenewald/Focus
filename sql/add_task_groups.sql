-- v7.10.43: TASK GROUPS (summary tasks), Richard 2026-11-14/15: tasks may be grouped under a parent
-- task, MS Project style — the grid numbers them 1, 1.1, 1.2.1 …, a group's dates, hours, progress
-- and status are rolled up from the tasks in it by the app (and written onto its row, so every reader
-- of project_tasks sees them), and a group collapses in the grid, the list and the Gantt.
-- Additive, re-runnable, SQL-editor safe. Nothing is removed.
ALTER TABLE project_tasks ADD COLUMN IF NOT EXISTS parent_task_id BIGINT REFERENCES project_tasks(id) ON DELETE CASCADE;
CREATE INDEX IF NOT EXISTS project_tasks_parent_idx ON project_tasks(parent_task_id) WHERE parent_task_id IS NOT NULL;
COMMENT ON COLUMN project_tasks.parent_task_id IS 'The group (summary task) this task sits in; NULL = a top-level task. A task with children is a group and carries no dates, hours or status of its own — the app writes the roll-up onto it.';

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'project_tasks_not_own_parent') THEN
    ALTER TABLE project_tasks ADD CONSTRAINT project_tasks_not_own_parent CHECK (parent_task_id IS NULL OR parent_task_id <> id);
  END IF;
END $$;

-- A parent must sit on the same plan and must not be a descendant of the task (no loops).
CREATE OR REPLACE FUNCTION project_tasks_parent_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $$
DECLARE v_plan BIGINT; v_loop BOOLEAN;
BEGIN
  IF NEW.parent_task_id IS NULL THEN RETURN NEW; END IF;
  SELECT plan_id INTO v_plan FROM project_tasks WHERE id = NEW.parent_task_id;
  IF v_plan IS NULL THEN RAISE EXCEPTION 'The parent task does not exist'; END IF;
  IF v_plan <> NEW.plan_id THEN RAISE EXCEPTION 'A task can only be grouped under a task on the same plan'; END IF;
  WITH RECURSIVE up AS (
    SELECT id, parent_task_id, 1 AS depth FROM project_tasks WHERE id = NEW.parent_task_id
    UNION ALL
    SELECT t.id, t.parent_task_id, up.depth + 1 FROM project_tasks t JOIN up ON t.id = up.parent_task_id WHERE up.depth < 200
  )
  SELECT EXISTS (SELECT 1 FROM up WHERE id = NEW.id) INTO v_loop;
  IF v_loop THEN RAISE EXCEPTION 'A task cannot be grouped under one of its own tasks'; END IF;
  RETURN NEW;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_project_tasks_parent_guard') THEN
    CREATE TRIGGER trg_project_tasks_parent_guard BEFORE INSERT OR UPDATE OF parent_task_id, plan_id ON project_tasks
      FOR EACH ROW EXECUTE FUNCTION project_tasks_parent_guard();
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
