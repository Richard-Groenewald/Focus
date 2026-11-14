-- v7.10.36 — task durations in minutes, hours or days (Richard 2026-11-14: "on duration setting, give options, hours/min/days").
-- The schedule still works in WORKING DAYS: duration_days holds the figure in days (an hour is a fraction of the
-- working day — settings.time_normal_start / time_normal_end, 9 h on the seed — and the calendar rounds a task
-- up to whole days), duration_unit only remembers how the figure is shown and typed.
-- Additive, re-runnable, SQL-editor safe. Run on DEV and PROD after sql/add_project_schedule.sql.
-- No DROP in this file (the Supabase MCP waits for a confirmation on that word).
ALTER TABLE public.project_tasks ALTER COLUMN duration_days TYPE NUMERIC(10,5) USING duration_days::numeric;
ALTER TABLE public.project_tasks ADD COLUMN IF NOT EXISTS duration_unit TEXT NOT NULL DEFAULT 'd';
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'project_tasks_duration_unit_check') THEN
    ALTER TABLE public.project_tasks ADD CONSTRAINT project_tasks_duration_unit_check CHECK (duration_unit IN ('m', 'h', 'd'));
  END IF;
END $$;
NOTIFY pgrst, 'reload schema';
SELECT column_name, data_type, numeric_precision, numeric_scale FROM information_schema.columns
 WHERE table_name = 'project_tasks' AND column_name IN ('duration_days', 'duration_unit');
