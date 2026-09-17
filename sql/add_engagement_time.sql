-- Engagement time + internal work (v7.8.51).
-- Run on BOTH databases (prod first at release, per the release recipe).
--
-- WHY. Focus has never had anywhere to record how long something took, and no way
-- to say "this was our own work on the account" as opposed to "this was contact
-- with the client". Les worked around both by creating a fake lead — "Xone
-- Security - INTERNAL BUS DEV MEETINGS" (prod lead 4154) — pushing it to Qualified
-- so it would stay put, and writing durations into the notes as free text
-- ("90min Teams meeting...", "x 7 hours"). The cost of that workaround: a phantom
-- Qualified lead in her contract metrics, and nine "Met with decision maker"
-- milestones on internal meetings with her own MD — a quarter of every milestone
-- of that type in the database. sql/migrate_internal_bus_dev_lead.sql moves that
-- data onto the structures below and removes the container.
--
-- SHAPE. Deliberately narrow, but laid out so the later timesheet module (hours
-- against projects and contracts, across Focus) extends it rather than replaces
-- it: time lives on the engagement, the project dimension is its own table that
-- can already point at an organisation or a deal, and v_time_entries is the
-- normalised surface a broader build reports from.

-- ── 1. How long it took ──────────────────────────────────────────────────────
-- Minutes, on ANY engagement — client-facing or internal. Nullable: the vast
-- majority of historical rows will never have it, and that is not an error.
ALTER TABLE engagements ADD COLUMN duration_minutes INTEGER
  CHECK (duration_minutes IS NULL OR (duration_minutes > 0 AND duration_minutes <= 1440));

-- ── 2. Contact with the client, or work on the account ───────────────────────
-- 'client'   = an outward touch: a call, a meeting, an email TO someone.
-- 'internal' = our own effort: proposal prep, research, an internal meeting.
-- Internal work still belongs to the record it advances, and still shows in that
-- record's history — but it is NOT a touch, so it must not bump last_touch_date,
-- satisfy a cadence step, or count toward the five-a-day. That distinction is the
-- whole reason the Willowton proposal work ended up parked on a fake lead.
ALTER TABLE engagements ADD COLUMN work_mode TEXT NOT NULL DEFAULT 'client'
  CHECK (work_mode IN ('client', 'internal'));

CREATE INDEX idx_engagements_work_mode ON engagements(work_mode);
CREATE INDEX idx_engagements_duration ON engagements(engagement_date) WHERE duration_minutes IS NOT NULL;

-- ── 3. Work projects ─────────────────────────────────────────────────────────
-- Internal work with no prospect behind it at all (the Bus Dev project, Focus
-- development, admin). Today only `kind = 'internal'` is used and only
-- engagements point here. organisation_id / deal_id are the hooks the later
-- timesheet module needs to log client and contract project time against the
-- same table, so the broader build inherits this one instead of forking it.
CREATE TABLE work_projects (
  id              BIGSERIAL PRIMARY KEY,
  name            TEXT NOT NULL,
  code            TEXT,
  kind            TEXT NOT NULL DEFAULT 'internal' CHECK (kind IN ('internal', 'client', 'overhead')),
  organisation_id BIGINT REFERENCES organisations(id),
  deal_id         BIGINT REFERENCES deals(id),
  owner_id        BIGINT REFERENCES people(id),
  notes           TEXT,
  sort_order      INTEGER,
  active          BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by      BIGINT REFERENCES people(id),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_work_projects_name ON work_projects(lower(name));
CREATE INDEX idx_work_projects_active ON work_projects(active, sort_order);

-- Audit trail, same as every other lookup. Trigger function ships with
-- sql/add_audit_log.sql.
CREATE TRIGGER audit_work_projects
  AFTER INSERT OR UPDATE OR DELETE ON work_projects
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

-- ── 4. An engagement may hang off a work project ─────────────────────────────
-- The exactly-one-target rule stands; there are simply three kinds of target now.
ALTER TABLE engagements ADD COLUMN work_project_id BIGINT REFERENCES work_projects(id);
CREATE INDEX idx_engagements_work_project ON engagements(work_project_id);

ALTER TABLE engagements DROP CONSTRAINT engagements_one_target_chk;
ALTER TABLE engagements ADD CONSTRAINT engagements_one_target_chk
  CHECK (num_nonnulls(lead_id, deal_id, work_project_id) = 1);

-- Project work is internal by definition — there is no client on the other end.
ALTER TABLE engagements ADD CONSTRAINT engagements_project_is_internal_chk
  CHECK (work_project_id IS NULL OR work_mode = 'internal');

-- ── 5. Seed the projects Les is actually working on ──────────────────────────
INSERT INTO work_projects (name, kind, sort_order, notes) VALUES
  ('Bus Dev Project',   'internal', 10, 'Business development engagement: strategy, contract and objectives.'),
  ('Focus Development', 'internal', 20, 'Working sessions on Focus itself — troubleshooting, specification, testing.'),
  ('Admin & Internal',  'internal', 30, 'Internal administration, planning and anything that is not client-facing.');

-- ── 6. The surface a broader timesheet build reports from ────────────────────
-- One row per recorded unit of time, whatever it was spent on. When the timesheet
-- module lands with its own entry table, it UNIONs into this view and every
-- existing report keeps working.
CREATE VIEW v_time_entries AS
SELECT e.id                AS engagement_id,
       e.created_by        AS person_id,
       e.engagement_date   AS entry_date,
       e.duration_minutes  AS minutes,
       e.work_mode,
       e.work_project_id,
       e.lead_id,
       e.deal_id,
       e.engagement_type,
       e.notes,
       'engagement'::TEXT  AS source
FROM engagements e
WHERE e.duration_minutes IS NOT NULL;

-- ── Verify ───────────────────────────────────────────────────────────────────
-- SELECT count(*) FROM work_projects;                         -- 3
-- SELECT count(*) FROM engagements WHERE work_mode <> 'client';  -- 0 before the data migration
-- SELECT * FROM v_time_entries LIMIT 5;                       -- empty until time is captured
