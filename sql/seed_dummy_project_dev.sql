-- DEV ONLY. A dummy secured PROJECT deal with a project plan, for trying the project planning
-- module (Focus v7.10.32, Richard 2026-11-13: "create a dummy project on dev").
-- Everything is labelled DUMMY so it can be found and deleted:
--   DELETE FROM deals WHERE name LIKE 'DUMMY —%';   -- the plan, milestones, tasks and team cascade.
-- Re-runnable: does nothing when the dummy deal already exists. Never run on PROD.

BEGIN;
SELECT set_config('focus.system', 'seed-dummy-project', true);

DO $$
DECLARE
  v_owner    BIGINT;   -- Richard: the deal's sales owner and therefore the project manager
  v_other    BIGINT;   -- a second home-org person for the team
  v_third    BIGINT;
  v_org      BIGINT;
  v_stage    BIGINT;   -- Secured
  v_major    BIGINT;
  v_sub      BIGINT;   -- a project-revenue service type
  v_deal     BIGINT;
  v_plan     BIGINT;
  v_m1 BIGINT; v_m2 BIGINT; v_m3 BIGINT;
BEGIN
  IF EXISTS (SELECT 1 FROM deals WHERE name LIKE 'DUMMY —%') THEN
    RAISE NOTICE 'dummy deal already exists — nothing done';
    RETURN;
  END IF;

  SELECT p.id INTO v_owner FROM people p JOIN system_users u ON u.person_id = p.id
   WHERE lower(p.first_name) = 'richard' ORDER BY p.id LIMIT 1;
  IF v_owner IS NULL THEN RAISE EXCEPTION 'no person named Richard with a login'; END IF;

  SELECT p.id INTO v_other FROM people p JOIN home_organisation_members h ON h.person_id = p.id
   WHERE p.id <> v_owner ORDER BY p.id LIMIT 1;
  SELECT p.id INTO v_third FROM people p JOIN home_organisation_members h ON h.person_id = p.id
   WHERE p.id NOT IN (v_owner, COALESCE(v_other, -1)) ORDER BY p.id LIMIT 1;

  SELECT id INTO v_stage FROM stages WHERE name = 'Secured' LIMIT 1;
  IF v_stage IS NULL THEN RAISE EXCEPTION 'no stage named Secured'; END IF;

  SELECT s.id, s.major_id INTO v_sub, v_major FROM service_sub s
   WHERE s.revenue_type = 'project' AND COALESCE(s.active, true) ORDER BY s.id LIMIT 1;
  IF v_sub IS NULL THEN RAISE EXCEPTION 'no project-revenue service type'; END IF;

  SELECT id INTO v_org FROM organisations
   WHERE COALESCE(active, true) AND COALESCE(org_kind, 'company') = 'company' AND COALESCE(is_client, false)
   ORDER BY name LIMIT 1;
  IF v_org IS NULL THEN
    SELECT id INTO v_org FROM organisations WHERE COALESCE(active, true) AND COALESCE(org_kind, 'company') = 'company' ORDER BY name LIMIT 1;
  END IF;

  INSERT INTO deals (name, org_id, stage_id, service_major_id, service_sub_id, margin_pct, probability,
                     order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type, notes, job_number)
  VALUES ('DUMMY — Control Room Build (project planning test)', v_org, v_stage, v_major, v_sub, 25.00, 100,
          CURRENT_DATE - 14, CURRENT_DATE - 7, CURRENT_DATE + 90, v_owner, v_owner, 'new_business',
          'Dummy secured project created on DEV to try the project planning module. Safe to delete.', 'PA-DUMMY')
  RETURNING id INTO v_deal;

  INSERT INTO project_plans (deal_id, kind, name, status, owner_id, planned_start, planned_end, notes, created_by, updated_by)
  VALUES (v_deal, 'project', 'DUMMY — Control Room Build', 'active', v_owner, CURRENT_DATE - 7, CURRENT_DATE + 90,
          'Dummy plan. Milestone 1 is done, milestone 2 has an overdue task so the plan reads Late.', v_owner, v_owner)
  RETURNING id INTO v_plan;

  INSERT INTO project_milestones (plan_id, name, due_date, owner_id, billing_pct, status, completed_at, sort_order, created_by)
  VALUES (v_plan, 'Design signed off',        CURRENT_DATE - 2,  v_owner, 20, 'done', now() - interval '2 days', 1, v_owner) RETURNING id INTO v_m1;
  INSERT INTO project_milestones (plan_id, name, due_date, owner_id, billing_pct, status, sort_order, created_by)
  VALUES (v_plan, 'Equipment installed',      CURRENT_DATE + 21, v_other, 50, 'open', 2, v_owner) RETURNING id INTO v_m2;
  INSERT INTO project_milestones (plan_id, name, due_date, owner_id, billing_pct, status, sort_order, created_by)
  VALUES (v_plan, 'Commissioned and handed over', CURRENT_DATE + 60, v_owner, 30, 'open', 3, v_owner) RETURNING id INTO v_m3;

  INSERT INTO project_tasks (plan_id, milestone_id, name, description, assignee_id, start_date, due_date, status, est_hours, completed_at, sort_order, created_by) VALUES
    (v_plan, v_m1, 'Site survey',                 'Walk the site and confirm camera positions.',    v_other, CURRENT_DATE - 7, CURRENT_DATE - 5, 'done',        6,  now() - interval '5 days', 1, v_owner),
    (v_plan, v_m1, 'Design drawings',             'Layout and cabling drawings for sign-off.',       v_owner, CURRENT_DATE - 5, CURRENT_DATE - 2, 'done',        12, now() - interval '2 days', 2, v_owner),
    (v_plan, v_m2, 'Order cameras and recorder',  NULL,                                              v_owner, CURRENT_DATE - 2, CURRENT_DATE - 1, 'in_progress', 2,  NULL, 1, v_owner),
    (v_plan, v_m2, 'Cabling',                     'Trunking and cable runs to the control room.',   v_other, CURRENT_DATE + 3, CURRENT_DATE + 12, 'todo',       40, NULL, 2, v_owner),
    (v_plan, v_m2, 'Mount and connect cameras',   NULL,                                              v_third, CURRENT_DATE + 12, CURRENT_DATE + 20, 'blocked',   24, NULL, 3, v_owner),
    (v_plan, v_m3, 'Configure recorder and VMS',  NULL,                                              v_other, CURRENT_DATE + 21, CURRENT_DATE + 30, 'todo',      16, NULL, 1, v_owner),
    (v_plan, v_m3, 'Operator training',           'Two sessions for the day and night shifts.',      v_owner, CURRENT_DATE + 45, CURRENT_DATE + 50, 'todo',      8,  NULL, 2, v_owner),
    (v_plan, NULL, 'Weekly client progress call', 'Not tied to a milestone.',                        v_owner, CURRENT_DATE,      CURRENT_DATE + 60, 'in_progress', 10, NULL, 1, v_owner);

  INSERT INTO project_plan_members (plan_id, person_id, role, created_by)
  SELECT v_plan, x.pid, x.role, v_owner FROM (VALUES (v_owner, 'Project manager'), (v_other, 'Technician'), (v_third, 'Installer')) x(pid, role)
   WHERE x.pid IS NOT NULL;

  RAISE NOTICE 'dummy deal % plan % (owner %, org %, service type %)', v_deal, v_plan, v_owner, v_org, v_sub;
END $$;

COMMIT;
