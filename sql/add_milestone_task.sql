-- v7.10.38: a milestone may mark the COMPLETION OF A TASK (Richard, 2026-11-14: "should one not be
-- able to set the completion of a task as a milestone?"). A tied milestone's due date follows the
-- task's scheduled finish and its status follows the task's; the app writes both onto the row, so
-- every reader of project_milestones (the Projects page, the deal tab, health) sees them as before.
-- Additive, re-runnable, SQL-editor safe. No DROP.
ALTER TABLE project_milestones ADD COLUMN IF NOT EXISTS task_id BIGINT REFERENCES project_tasks(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS project_milestones_task_idx ON project_milestones(task_id) WHERE task_id IS NOT NULL;
COMMENT ON COLUMN project_milestones.task_id IS 'The task whose completion this milestone marks (NULL = a milestone with a date of its own).';
NOTIFY pgrst, 'reload schema';
