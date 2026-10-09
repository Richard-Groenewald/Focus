-- Timesheets (v7.9.98). Additive and re-runnable; run on DEV first, then PROD, BEFORE or with the code.
--
-- WHY. Richard 2026-10-05: people on projects and maintenance must capture their time against the
-- individual job (the PA / CA numbers on the Work Labour Report) from a phone. The report he gave
-- as the example has one row per job: labour cost, normal hours, after hours, public-holiday hours,
-- mileage, split into Projects and Contracts. The paper source is Xone's PMSA service report.
--
-- SHAPE. v7.8.51 left the seam: work_projects (internal buckets) and v_time_entries (the surface a
-- timesheet module UNIONs into). A timesheet entry is a person, a day, a start and a finish, a
-- description and the job it was spent on - a DEAL carrying a job number (PA... project / CA...
-- contract; a contract or project is the same deals row, v7.9.84) or a work project. The hour
-- classes (normal / after hours / public holiday) are worked out in ONE place, the trigger below,
-- from settings and the public-holiday list, so the phone, the report and a later payroll export
-- can never disagree. Cost is never stored: it is hours x the person's rate effective on the day.
--
-- LIFECYCLE. draft -> submitted (the person submits a week) -> approved (a manager) or
-- returned (with a reason, editable again). Submitted and approved rows are locked by trigger;
-- only timesheet_submit / timesheet_decide (SECURITY DEFINER) move them, and an approver may
-- reopen an approved one. Offline capture: the phone stamps each entry with a client_uuid, so a
-- retried sync can never duplicate it.

BEGIN;

-- 1. The job number on the deal (PA3639, CA6119 ...). Unique where set.
ALTER TABLE deals ADD COLUMN IF NOT EXISTS job_number TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS deals_job_number_uq ON deals (lower(btrim(job_number))) WHERE job_number IS NOT NULL AND btrim(job_number) <> '';

-- 2. South African public holidays (editable). Observed dates are listed, not computed.
CREATE TABLE IF NOT EXISTS public_holidays (
  id           BIGSERIAL PRIMARY KEY,
  holiday_date DATE NOT NULL UNIQUE,
  name         TEXT NOT NULL,
  active       BOOLEAN NOT NULL DEFAULT TRUE
);
INSERT INTO public_holidays (holiday_date, name) VALUES
  ('2026-01-01', 'New Year''s Day'), ('2026-03-21', 'Human Rights Day'), ('2026-04-03', 'Good Friday'),
  ('2026-04-06', 'Family Day'), ('2026-04-27', 'Freedom Day'), ('2026-05-01', 'Workers'' Day'),
  ('2026-06-16', 'Youth Day'), ('2026-08-10', 'Women''s Day (observed)'), ('2026-09-24', 'Heritage Day'),
  ('2026-12-16', 'Day of Reconciliation'), ('2026-12-25', 'Christmas Day'), ('2026-12-26', 'Day of Goodwill'),
  ('2027-01-01', 'New Year''s Day'), ('2027-03-22', 'Human Rights Day (observed)'), ('2027-03-26', 'Good Friday'),
  ('2027-03-29', 'Family Day'), ('2027-04-27', 'Freedom Day'), ('2027-05-01', 'Workers'' Day'),
  ('2027-06-16', 'Youth Day'), ('2027-08-09', 'Women''s Day'), ('2027-09-24', 'Heritage Day'),
  ('2027-12-16', 'Day of Reconciliation'), ('2027-12-25', 'Christmas Day'), ('2027-12-27', 'Day of Goodwill (observed)')
ON CONFLICT (holiday_date) DO NOTHING;

-- 3. Labour cost rates, effective-dated. person_id NULL = the company default. Never edited: a new row
-- from a new date. The multipliers apply to the normal rate for after-hours and public-holiday time.
CREATE TABLE IF NOT EXISTS labour_rates (
  id                       BIGSERIAL PRIMARY KEY,
  person_id                BIGINT REFERENCES people(id),
  effective_from           DATE NOT NULL,
  normal_rate              NUMERIC(12,2) NOT NULL CHECK (normal_rate >= 0),
  after_hours_multiplier   NUMERIC(5,2)  NOT NULL DEFAULT 1.5 CHECK (after_hours_multiplier >= 0),
  holiday_multiplier       NUMERIC(5,2)  NOT NULL DEFAULT 2.0 CHECK (holiday_multiplier >= 0),
  notes                    TEXT,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by               BIGINT REFERENCES people(id)
);
CREATE UNIQUE INDEX IF NOT EXISTS labour_rates_person_from_uq ON labour_rates (COALESCE(person_id, 0), effective_from);

-- 4. Working-day settings (the day's normal window; Saturdays, Sundays and holidays are never normal).
INSERT INTO settings (key, value)
SELECT v.k, v.val FROM (VALUES ('time_normal_start', '08:00'), ('time_normal_end', '17:00')) AS v(k, val)
 WHERE NOT EXISTS (SELECT 1 FROM settings s WHERE s.key = v.k);

-- 5. The entries.
CREATE TABLE IF NOT EXISTS timesheet_entries (
  id               BIGSERIAL PRIMARY KEY,
  person_id        BIGINT NOT NULL REFERENCES people(id),
  entry_date       DATE   NOT NULL,
  start_time       TIME   NOT NULL,
  end_time         TIME   NOT NULL,
  deal_id          BIGINT REFERENCES deals(id),
  work_project_id  BIGINT REFERENCES work_projects(id),
  description      TEXT,
  km               NUMERIC(8,1) CHECK (km IS NULL OR km >= 0),
  pmsa_ref         TEXT,
  minutes          INTEGER,           -- derived by the trigger
  normal_minutes   INTEGER,           -- derived
  after_minutes    INTEGER,           -- derived
  holiday_minutes  INTEGER,           -- derived
  status           TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'submitted', 'approved', 'returned')),
  submitted_at     TIMESTAMPTZ,
  decided_by       BIGINT REFERENCES people(id),
  decided_at       TIMESTAMPTZ,
  return_reason    TEXT,
  client_uuid      TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by       BIGINT REFERENCES people(id),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT timesheet_one_job_chk CHECK (num_nonnulls(deal_id, work_project_id) = 1),
  CONSTRAINT timesheet_times_chk   CHECK (end_time > start_time)
);
-- Not partial: PostgREST's on_conflict=client_uuid must be able to infer it (NULLs never collide).
CREATE UNIQUE INDEX IF NOT EXISTS timesheet_client_uuid_uq ON timesheet_entries (client_uuid);
CREATE INDEX IF NOT EXISTS timesheet_person_date_idx ON timesheet_entries (person_id, entry_date);
CREATE INDEX IF NOT EXISTS timesheet_deal_idx        ON timesheet_entries (deal_id);
CREATE INDEX IF NOT EXISTS timesheet_status_idx      ON timesheet_entries (status);

-- 6. The one classifier: minutes by class for a day and a window.
CREATE OR REPLACE FUNCTION public.timesheet_classify(p_date date, p_start time, p_end time)
RETURNS TABLE (total int, normal int, after_hours int, holiday int)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_total int := (extract(epoch FROM (p_end - p_start)) / 60)::int;
  v_ns time := COALESCE(NULLIF((SELECT value FROM public.settings WHERE key = 'time_normal_start'), ''), '08:00')::time;
  v_ne time := COALESCE(NULLIF((SELECT value FROM public.settings WHERE key = 'time_normal_end'),   ''), '17:00')::time;
  v_norm int := 0;
BEGIN
  IF EXISTS (SELECT 1 FROM public.public_holidays WHERE holiday_date = p_date AND active) THEN
    RETURN QUERY SELECT v_total, 0, 0, v_total; RETURN;
  END IF;
  IF extract(isodow FROM p_date) BETWEEN 1 AND 5 THEN
    v_norm := GREATEST(0, (extract(epoch FROM (LEAST(p_end, v_ne) - GREATEST(p_start, v_ns))) / 60)::int);
  END IF;
  RETURN QUERY SELECT v_total, v_norm, v_total - v_norm, 0;
END $$;

-- 7. Row rules: derive the minutes, refuse overlap, lock what is submitted or approved.
CREATE OR REPLACE FUNCTION public.timesheet_rules() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  c record;
  internal boolean := COALESCE(current_setting('focus.ts_internal', true), '') = '1';
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status IN ('submitted', 'approved') AND NOT internal THEN
      RAISE EXCEPTION 'A % entry cannot be deleted', OLD.status;
    END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status IN ('submitted', 'approved') AND NOT internal THEN
    RAISE EXCEPTION 'A % entry is locked', OLD.status;
  END IF;
  IF NOT internal THEN
    IF TG_OP = 'INSERT' THEN NEW.status := 'draft'; END IF;
    IF TG_OP = 'UPDATE' THEN NEW.status := CASE WHEN OLD.status = 'returned' THEN 'draft' ELSE OLD.status END; END IF;
  END IF;
  IF NEW.entry_date > CURRENT_DATE + 1 THEN RAISE EXCEPTION 'Time cannot be captured for a future date'; END IF;
  SELECT * INTO c FROM public.timesheet_classify(NEW.entry_date, NEW.start_time, NEW.end_time);
  NEW.minutes := c.total; NEW.normal_minutes := c.normal; NEW.after_minutes := c.after_hours; NEW.holiday_minutes := c.holiday;
  IF EXISTS (SELECT 1 FROM public.timesheet_entries t
              WHERE t.person_id = NEW.person_id AND t.entry_date = NEW.entry_date
                AND t.id IS DISTINCT FROM NEW.id
                AND t.start_time < NEW.end_time AND t.end_time > NEW.start_time) THEN
    RAISE EXCEPTION 'This overlaps another entry on %', to_char(NEW.entry_date, 'DD Mon YYYY');
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS timesheet_rules_trg ON timesheet_entries;
CREATE TRIGGER timesheet_rules_trg BEFORE INSERT OR UPDATE OR DELETE ON timesheet_entries
  FOR EACH ROW EXECUTE FUNCTION public.timesheet_rules();

-- 8. Submit a person's draft / returned entries in a date range.
CREATE OR REPLACE FUNCTION public.timesheet_submit(p_person_id bigint, p_from date, p_to date)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n int;
BEGIN
  PERFORM set_config('focus.ts_internal', '1', true);
  UPDATE timesheet_entries SET status = 'submitted', submitted_at = now(), return_reason = NULL
   WHERE person_id = p_person_id AND entry_date BETWEEN p_from AND p_to AND status IN ('draft', 'returned');
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM set_config('focus.ts_internal', '', true);
  RETURN n;
END $$;

-- 9. An approver decides: approve | return (reason required) | reopen (approved -> returned).
CREATE OR REPLACE FUNCTION public.timesheet_decide(p_actor_id bigint, p_entry_ids bigint[], p_decision text, p_reason text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n int;
BEGIN
  IF NOT public.person_has_permission(p_actor_id, 'approve_timesheets') THEN
    RAISE EXCEPTION 'You do not have permission to approve timesheets';
  END IF;
  IF EXISTS (SELECT 1 FROM timesheet_entries WHERE id = ANY(p_entry_ids) AND person_id = p_actor_id) THEN
    RAISE EXCEPTION 'You cannot approve or return your own time';
  END IF;
  PERFORM set_config('focus.ts_internal', '1', true);
  IF p_decision = 'approve' THEN
    UPDATE timesheet_entries SET status = 'approved', decided_by = p_actor_id, decided_at = now(), return_reason = NULL
     WHERE id = ANY(p_entry_ids) AND status = 'submitted';
  ELSIF p_decision = 'return' THEN
    IF COALESCE(btrim(p_reason), '') = '' THEN RAISE EXCEPTION 'Say why the time is being returned'; END IF;
    UPDATE timesheet_entries SET status = 'returned', decided_by = p_actor_id, decided_at = now(), return_reason = p_reason
     WHERE id = ANY(p_entry_ids) AND status = 'submitted';
  ELSIF p_decision = 'reopen' THEN
    IF COALESCE(btrim(p_reason), '') = '' THEN RAISE EXCEPTION 'Say why the approved time is being reopened'; END IF;
    UPDATE timesheet_entries SET status = 'returned', decided_by = p_actor_id, decided_at = now(), return_reason = p_reason
     WHERE id = ANY(p_entry_ids) AND status = 'approved';
  ELSE
    RAISE EXCEPTION 'Unknown decision %', p_decision;
  END IF;
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM set_config('focus.ts_internal', '', true);
  RETURN n;
END $$;

-- 10. Costed rows for the report: the rate in force on the day (the person's own, else the company default).
CREATE OR REPLACE VIEW v_timesheet_costed AS
SELECT t.*,
       r.normal_rate, r.after_hours_multiplier, r.holiday_multiplier,
       CASE WHEN r.id IS NULL THEN NULL ELSE round(
         (t.normal_minutes * r.normal_rate
          + t.after_minutes * r.normal_rate * r.after_hours_multiplier
          + t.holiday_minutes * r.normal_rate * r.holiday_multiplier) / 60.0, 2) END AS labour_cost
FROM timesheet_entries t
LEFT JOIN LATERAL (
  SELECT x.* FROM labour_rates x
   WHERE (x.person_id = t.person_id OR x.person_id IS NULL) AND x.effective_from <= t.entry_date
   ORDER BY (x.person_id IS NOT NULL) DESC, x.effective_from DESC LIMIT 1
) r ON TRUE;

-- 11. The wider time surface gains the timesheet rows (columns appended, existing ones untouched).
CREATE OR REPLACE VIEW v_time_entries AS
SELECT e.id AS engagement_id, e.created_by AS person_id, e.engagement_date AS entry_date,
       e.duration_minutes AS minutes, e.work_mode, e.work_project_id, e.lead_id, e.deal_id,
       e.engagement_type, e.notes, 'engagement'::TEXT AS source, NULL::BIGINT AS timesheet_entry_id
FROM engagements e WHERE e.duration_minutes IS NOT NULL
UNION ALL
SELECT NULL, t.person_id, t.entry_date, t.minutes, 'internal', t.work_project_id, NULL, t.deal_id,
       NULL, t.description, 'timesheet', t.id
FROM timesheet_entries t;

-- 12. Permissions and the Technician role.
INSERT INTO permissions (name, description)
SELECT v.n, v.d FROM (VALUES
  ('capture_time',        'Capture own time on the timesheet (mobile)'),
  ('approve_timesheets',  'Approve or return submitted timesheets'),
  ('view_labour_report',  'View the Work Labour Report, including labour cost'),
  ('manage_labour_rates', 'Maintain labour cost rates, public holidays and job numbers')) AS v(n, d)
 WHERE NOT EXISTS (SELECT 1 FROM permissions p WHERE p.name = v.n);

INSERT INTO roles (name, description, is_system)
SELECT 'Technician', 'Field staff: captures own time on the mobile timesheet', false
 WHERE NOT EXISTS (SELECT 1 FROM roles WHERE name = 'Technician');

INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r JOIN permissions p ON
  (r.name = 'Technician' AND p.name = 'capture_time')
  OR (r.name = 'Executive' AND p.name IN ('capture_time', 'approve_timesheets', 'view_labour_report', 'manage_labour_rates'))
WHERE NOT EXISTS (SELECT 1 FROM role_permissions x WHERE x.role_id = r.id AND x.permission_id = p.id);

-- 13. RLS + grants + audit, like every other table.
ALTER TABLE public_holidays   ENABLE ROW LEVEL SECURITY;
ALTER TABLE labour_rates      ENABLE ROW LEVEL SECURITY;
ALTER TABLE timesheet_entries ENABLE ROW LEVEL SECURITY;
GRANT ALL ON public_holidays, labour_rates, timesheet_entries TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public_holidays_id_seq, labour_rates_id_seq, timesheet_entries_id_seq TO service_role;
GRANT SELECT ON v_timesheet_costed, v_time_entries TO service_role;
GRANT EXECUTE ON FUNCTION public.timesheet_classify(date, time, time), public.timesheet_submit(bigint, date, date),
  public.timesheet_decide(bigint, bigint[], text, text) TO service_role;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['public_holidays', 'labour_rates', 'timesheet_entries'] LOOP
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

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Verify:
-- SELECT * FROM timesheet_classify('2026-10-05', '07:00', '19:00');   -- Mon: 12h = 9 normal, 3 after
-- SELECT * FROM timesheet_classify('2026-10-10', '08:00', '12:00');   -- Sat: all after hours
-- SELECT * FROM timesheet_classify('2026-09-24', '08:00', '12:00');   -- Heritage Day: all holiday
