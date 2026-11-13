-- Project planning, phase 1 (Focus v7.10.32, Richard 2026-11-13: "projects are distinct from
-- contracts. when a project is secured, the assigned project owner will be given the option to
-- build a project plan" / "in contracts, the start up phase may well be defined as a project" /
-- "build, make sales person pm").
--
-- A PLAN hangs off ONE secured deal: a project-revenue deal (kind 'project') or the start-up phase
-- of a contract (kind 'startup'). It is never created automatically; the project manager (the
-- deal's sales owner by default, held on the plan so it can be handed over) builds it from the
-- deal page and it starts empty.
--   project_plans         one per deal: kind, name, status, planned dates, the project manager
--   project_milestones    due date, owner, optional billing %, open / done
--   project_tasks         under a milestone or none: assignee, start / due, status, estimated hours
--   project_plan_members  the project team (people rows - login or not - with a free-text role)
-- Health (on track / at risk / late) is derived in the client from due dates, never stored.
-- Phase 1 holds no dependencies, capacity or time against tasks (timesheet_entries untouched).
--
-- Additive, re-runnable, SQL-editor safe. Run on DEV first, then PROD, with or before the code:
-- a database without these tables shows the Project Plan tab empty and names this file.

BEGIN;

CREATE TABLE IF NOT EXISTS project_plans (
  id             BIGSERIAL PRIMARY KEY,
  deal_id        BIGINT NOT NULL UNIQUE REFERENCES deals(id) ON DELETE CASCADE,
  kind           TEXT NOT NULL DEFAULT 'project' CHECK (kind IN ('project', 'startup')),
  name           TEXT NOT NULL,
  status         TEXT NOT NULL DEFAULT 'planning' CHECK (status IN ('planning', 'active', 'on_hold', 'complete')),
  owner_id       BIGINT REFERENCES people(id),          -- the project manager: the deal's sales owner when built
  planned_start  DATE,
  planned_end    DATE,
  notes          TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by     BIGINT REFERENCES people(id),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by     BIGINT REFERENCES people(id),
  CONSTRAINT project_plans_dates_chk CHECK (planned_start IS NULL OR planned_end IS NULL OR planned_end >= planned_start)
);

CREATE TABLE IF NOT EXISTS project_milestones (
  id             BIGSERIAL PRIMARY KEY,
  plan_id        BIGINT NOT NULL REFERENCES project_plans(id) ON DELETE CASCADE,
  name           TEXT NOT NULL,
  due_date       DATE,
  owner_id       BIGINT REFERENCES people(id),
  billing_pct    NUMERIC(5,2) CHECK (billing_pct IS NULL OR (billing_pct >= 0 AND billing_pct <= 100)),
  status         TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'done')),
  completed_at   TIMESTAMPTZ,
  sort_order     INTEGER NOT NULL DEFAULT 0,
  notes          TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by     BIGINT REFERENCES people(id),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS project_milestones_plan_idx ON project_milestones (plan_id, sort_order);

CREATE TABLE IF NOT EXISTS project_tasks (
  id             BIGSERIAL PRIMARY KEY,
  plan_id        BIGINT NOT NULL REFERENCES project_plans(id) ON DELETE CASCADE,
  milestone_id   BIGINT REFERENCES project_milestones(id) ON DELETE SET NULL,   -- a task may sit under no milestone
  name           TEXT NOT NULL,
  description    TEXT,
  assignee_id    BIGINT REFERENCES people(id),
  start_date     DATE,
  due_date       DATE,
  status         TEXT NOT NULL DEFAULT 'todo' CHECK (status IN ('todo', 'in_progress', 'blocked', 'done')),
  est_hours      NUMERIC(8,2) CHECK (est_hours IS NULL OR est_hours >= 0),
  completed_at   TIMESTAMPTZ,
  sort_order     INTEGER NOT NULL DEFAULT 0,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by     BIGINT REFERENCES people(id),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT project_tasks_dates_chk CHECK (start_date IS NULL OR due_date IS NULL OR due_date >= start_date)
);
CREATE INDEX IF NOT EXISTS project_tasks_plan_idx ON project_tasks (plan_id, milestone_id, sort_order);
CREATE INDEX IF NOT EXISTS project_tasks_assignee_idx ON project_tasks (assignee_id) WHERE status <> 'done';

CREATE TABLE IF NOT EXISTS project_plan_members (
  id             BIGSERIAL PRIMARY KEY,
  plan_id        BIGINT NOT NULL REFERENCES project_plans(id) ON DELETE CASCADE,
  person_id      BIGINT NOT NULL REFERENCES people(id),
  role           TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by     BIGINT REFERENCES people(id),
  UNIQUE (plan_id, person_id)
);

-- The permission: build and edit ANY plan. The project manager edits their own plan without it,
-- a team member moves their own tasks, and anyone who can open the deal reads the plan.
INSERT INTO permissions (name, description)
SELECT 'manage_project_plans', 'Build and edit any project plan (milestones, tasks, team)'
 WHERE NOT EXISTS (SELECT 1 FROM permissions WHERE name = 'manage_project_plans');
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r JOIN permissions p ON p.name = 'manage_project_plans'
 WHERE r.name IN ('Admin', 'Executive')
   AND NOT EXISTS (SELECT 1 FROM role_permissions x WHERE x.role_id = r.id AND x.permission_id = p.id);

ALTER TABLE project_plans        ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_milestones   ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_tasks        ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_plan_members ENABLE ROW LEVEL SECURITY;
GRANT ALL ON project_plans, project_milestones, project_tasks, project_plan_members TO service_role;
GRANT USAGE, SELECT ON SEQUENCE project_plans_id_seq, project_milestones_id_seq, project_tasks_id_seq, project_plan_members_id_seq TO service_role;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['project_plans', 'project_milestones', 'project_tasks', 'project_plan_members'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_ins_' || t) THEN
      EXECUTE format('CREATE TRIGGER audit_ins_%1$I AFTER INSERT ON %1$I REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_upd_' || t) THEN
      EXECUTE format('CREATE TRIGGER audit_upd_%1$I AFTER UPDATE ON %1$I REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_del_' || t) THEN
      EXECUTE format('CREATE TRIGGER audit_del_%1$I AFTER DELETE ON %1$I REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
    END IF;
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';
COMMIT;
